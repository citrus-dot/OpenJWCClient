import Foundation
import GRDB
import OpenJWCCore

/// 拖拽共享状态（直译 Android TimetableDragState）：位置为「网格内容坐标系」pt 偏移
/// （内容区左上角为原点，已含左侧节次标签宽度）。
@Observable
final class TimetableDragState {
    private(set) var draggingCourse: CourseRecord?
    private(set) var dragPosition: CGPoint = .zero
    private(set) var originalPosition: CGPoint = .zero
    /// 原块尺寸，用于浮层出现时从原尺寸平滑过渡到目标尺寸。
    private(set) var startWidth: CGFloat = 0
    private(set) var startHeight: CGFloat = 0
    /// 落位/回弹动画的缩放覆盖（1.06→1.00）；nil = 正常缩放。
    var settleScale: Float?
    /// 手势会话存活标志：长按成立 → true；end/cancel/系统中断复位。
    /// 块视图据此防重入（历史 bug：本地 @State 与全局脱节导致块永久卡死）。
    private(set) var gestureAlive = false

    var isDragging: Bool { draggingCourse != nil }

    /// 是否允许开始一次新拖拽（无进行中会话）。
    func canStart() -> Bool {
        !gestureAlive
    }

    func start(course: CourseRecord, blockTopLeft: CGPoint, width: CGFloat, height: CGFloat) {
        guard canStart() else { return }
        gestureAlive = true
        draggingCourse = course
        originalPosition = blockTopLeft
        dragPosition = blockTopLeft
        startWidth = width
        startHeight = height
    }

    func drag(dx: CGFloat, dy: CGFloat) {
        guard gestureAlive else { return }
        dragPosition.x += dx
        dragPosition.y += dy
    }

    func moveTo(_ position: CGPoint) {
        guard gestureAlive else { return }
        dragPosition = position
    }

    /// 全量复位（end/cancel/兜底/系统中断共用；任何泄漏状态在此归零）。
    func reset() {
        draggingCourse = nil
        dragPosition = .zero
        originalPosition = .zero
        startWidth = 0
        startHeight = 0
        settleScale = nil
        gestureAlive = false
    }
}

/// 课表数据快照（观察闭包一次组装，removeDuplicates 后整体推送）。
struct TimetableDataSnapshot: Equatable {
    var tables: [TableMetadataRecord]
    var current: TableMetadataRecord?
    var courses: [CourseRecord]

    static func == (lhs: TimetableDataSnapshot, rhs: TimetableDataSnapshot) -> Bool {
        lhs.tables == rhs.tables && lhs.current == rhs.current
            && lhs.courses.count == rhs.courses.count
            && zip(lhs.courses, rhs.courses).allSatisfy(==)
    }
}

/// 课表 tab 状态机（对齐 Android TimetableViewModel）：
/// 单闭包 ValueObservation 多表组装 + currentWeek 状态机 + 分钟对齐当前节 + 拖拽状态。
@MainActor
@Observable
final class TimetableStore {
    private(set) var snapshot = TimetableDataSnapshot(tables: [], current: nil, courses: [])

    /// 当前周（pager 双向同步；表切换/开学日期变更时重算）。
    private(set) var currentWeek = 1
    /// 当前活跃节索引（0-based；分钟对齐刷新）。-1 = 无课进行中。
    private(set) var activePeriodIndex = -1
    /// 当前时刻的「今天午夜起分钟数」（指示线插值用）。
    private(set) var nowMinuteOfDay = 0

    let dragState = TimetableDragState()

    private let database: any DatabaseWriter
    private let settings: SettingsStore
    private let dao: TimetableDao
    private var observation: (any DatabaseCancellable)?
    /// 内部周更新标志（程序改周无动画滚动；外部滑页才回写）。对齐 Android isInternalWeekUpdate。
    private var internalWeekUpdate = false
    private var minuteTask: Task<Void, Never>?

    init(db: any DatabaseWriter, settings: SettingsStore) {
        self.database = db
        self.settings = settings
        self.dao = TimetableDao(db: db)
        startObservation()
        startMinuteLoop()
    }

    // MARK: - 派生

    var currentTable: TableMetadataRecord? { snapshot.current }
    var courses: [CourseRecord] { snapshot.courses }
    var config: SemesterConfig? { snapshot.current?.semesterConfig }

    /// 显示开关（读 UserSettings 快照；Me 设置页保存后由视图重读）。
    var displayPrefs: (timeline: Bool, date: Bool, periodTime: Bool, nonCurrentWeek: Bool) {
        let s = settings.loadUserSettings()
        return (s.showTimeline, s.showDate, s.showPeriodTime, s.showNonCurrentWeek)
    }

    /// 当周显示的课程（weekRule 含当前周）。
    func coursesVisible(inWeek week: Int) -> [CourseRecord] {
        snapshot.courses.filter { $0.weekRule.value.contains(week) }
    }

    // MARK: - 周切换（D-3 双向同步）

    /// 用户滑页落定 → 更新周（外部驱动）。
    func setWeek(fromPage page: Int) {
        let week = page + 1
        guard week != currentWeek else { return }
        currentWeek = week
    }

    /// 程序切周（表切换/数据重算）→ 无动画滚动到对应页（内部驱动）。
    func programmaticWeek(_ week: Int) {
        internalWeekUpdate = true
        currentWeek = week
    }

    /// 消费内部标志（视图层判断滚动动画方式后调用）。
    func consumeInternalWeekFlag() -> Bool {
        let value = internalWeekUpdate
        internalWeekUpdate = false
        return value
    }

    /// 表切换/开学日期变更：重算当前周（周一为首、越界回 1、学期内 clamp）。
    func recomputeCurrentWeek() {
        guard let config = config else {
            programmaticWeek(1)
            return
        }
        let week = GrdbTimetableSource.currentWeek(
            startDate: config.startDate, weeks: config.weeks,
            today: Date(), timeZone: .current
        ) ?? 1
        programmaticWeek(week)
    }

    // MARK: - 数据变更（供视图/菜单调用，经 TimetableService 或直写后观察自动刷新）

    func moveCourse(_ course: CourseRecord, toDay day: Int, startPeriod: Int) async {
        guard let courseId = course.id else {
            NSLog("TimetableStore.moveCourse 拒绝：course.id 为 nil")
            return
        }
        do {
            let rows = try await dao.updateCoursePosition(
                courseId: courseId, dayOfWeek: day, startPeriod: startPeriod
            )
            NSLog("TimetableStore.moveCourse id=%lld → day=%d period=%d rows=%lld", courseId, day, startPeriod, rows)
            if rows == 0 {
                NSLog("TimetableStore.moveCourse 警告：UPDATE 未命中任何行（id 不存在？）")
            }
        } catch {
            NSLog("TimetableStore.moveCourse 失败: \(error)")
        }
    }

    // MARK: - 观察与分钟循环

    private func startObservation() {
        let observation = ValueObservation.tracking { db -> TimetableDataSnapshot in
            let tables = try TimetableDao.allTablesSync(db)
            let current = tables.first(where: \.isCurrent)
            let courses = try current.map { try TimetableDao.coursesSync(db, tableId: $0.id ?? 0) } ?? []
            return TimetableDataSnapshot(tables: tables, current: current, courses: courses)
        }
        .removeDuplicates()
        self.observation = observation.start(in: database, onError: { NSLog("TimetableStore 观察错误: \($0)") }) { [weak self] value in
            NSLog("TimetableStore 推送: tables=%d current=%@ courses=%d",
                  value.tables.count, value.current?.tableName ?? "nil", value.courses.count)
            Task { @MainActor in
                guard let self else { return }
                let hadTable = self.snapshot.current != nil
                self.snapshot = value
                // 表切换或首次出现表 → 重算当前周
                if !hadTable && value.current != nil {
                    self.recomputeCurrentWeek()
                }
            }
        }
    }

    /// 分钟对齐循环（Android delay(60_000 − now%60_000) 等价）：刷新当前节与指示线时刻。
    private func startMinuteLoop() {
        func refreshNow() {
            let now = Date()
            let calendar = Calendar.current
            let comps = calendar.dateComponents([.hour, .minute, .second], from: now)
            nowMinuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            activePeriodIndex = Self.activePeriod(
                minuteOfDay: nowMinuteOfDay, periods: config?.periods ?? []
            )
        }
        minuteTask = Task { [weak self] in
            while !Task.isCancelled {
                refreshNow()
                let seconds = Calendar.current.dateComponents([.second], from: Date()).second ?? 0
                try? await Task.sleep(for: .seconds(60 - seconds % 60))
            }
        }
    }

    /// 当前活跃节索引（0-based；-1 = 界外）。节内/节间均返回「下一节上缘」语义的节号。
    static func activePeriod(minuteOfDay: Int, periods: [SemesterConfig.Period]) -> Int {
        guard let first = periods.first, let last = periods.last else { return -1 }
        guard let startMinutes = Self.minutes(first.start),
              let endMinutes = Self.minutes(last.end) else { return -1 }
        guard minuteOfDay >= startMinutes, minuteOfDay <= endMinutes else { return -1 }

        for (i, p) in periods.enumerated() {
            guard let s = Self.minutes(p.start), let e = Self.minutes(p.end) else { continue }
            if minuteOfDay >= s, minuteOfDay <= e {
                return i
            }
            if i < periods.count - 1,
               let nextStart = Self.minutes(periods[i + 1].start),
               minuteOfDay > e, minuteOfDay < nextStart {
                return i + 1
            }
        }
        return -1
    }

    /// 指示线 Y 偏移（节单位浮点；直译 calculateTimeLineOffset）。nil = 界外。
    static func timeLineOffsetPeriods(
        minuteOfDay: Int, periods: [SemesterConfig.Period]
    ) -> Double? {
        guard let first = periods.first, let last = periods.last,
              let firstStart = minutes(first.start), let lastEnd = minutes(last.end),
              minuteOfDay >= firstStart, minuteOfDay <= lastEnd else { return nil }
        for (i, p) in periods.enumerated() {
            guard let s = minutes(p.start), let e = minutes(p.end) else { continue }
            if minuteOfDay >= s, minuteOfDay <= e {
                let total = max(e - s, 1)
                return Double(i) + Double(minuteOfDay - s) / Double(total)
            }
            if i < periods.count - 1,
               let nextStart = minutes(periods[i + 1].start),
               minuteOfDay > e, minuteOfDay < nextStart {
                return Double(i + 1)
            }
        }
        return nil
    }

    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}
