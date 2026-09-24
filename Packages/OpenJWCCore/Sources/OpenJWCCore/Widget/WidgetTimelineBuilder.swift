import Foundation

/// 小组件时间线生成纯函数（design D-6）：
/// 节次边界 entry（推进剩余过滤与切日判定）+ 进行中课程分钟粒度 entry（倒计时推进）
/// + 午夜后切日 entry（00:05，对齐 Android）+ 缺失快照回退空态；entry 时刻单调，末尾 `.atEnd` 刷新。
/// 纯本地计算（无网络），时间线将「未来的显示状态」预生成交给系统。
public enum WidgetTimelineBuilder {

    public struct Entry: Equatable, Sendable {
        public var date: Date
        public var state: WidgetDisplayState

        public init(date: Date, state: WidgetDisplayState) {
            self.date = date
            self.state = state
        }
    }

    /// 切日 entry 偏移：午夜后 00:05（对齐 Android）。
    static let dayRollMinute = 5
    /// entry 数量保护上限（保近端；典型课表远低于此值）。
    static let maxEntries = 500

    /// 生成时间线。snapshot 为 nil（未导出/解码失败）→ 空态 entry（不崩溃，spec「快照缺失回退」）。
    /// 覆盖窗口：from 起 horizonDays 天（默认今天剩余 + 明天）。
    public static func build(
        snapshot: WidgetSnapshot?, date: Date,
        timeZone: TimeZone = .current,
        horizonDays: Int = 2
    ) -> [Entry] {
        guard let snapshot else {
            return [Entry(date: date, state: WidgetDisplayState(
                showsTomorrow: false, weekNumber: nil, courses: [], emptyMessage: "今天没有课"
            ))]
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayStart = calendar.startOfDay(for: date)

        // 1. 收集关键时间点：节次边界 / 17:00 与末课切换点 / 每日 00:05 切日
        var marks = Set<Date>()
        marks.insert(date) // 当前状态首 entry
        for dayOffset in 0..<max(horizonDays, 1) {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: dayStart) else { continue }
            let dayCourses = WidgetDisplayState.compute(snapshot: snapshot, date: day, timeZone: timeZone)
            // 该日全部课程边界（无论过滤与否——状态推进依赖完整边界）
            if let courses = courses(on: day, snapshot: snapshot, timeZone: timeZone) {
                for course in courses {
                    for text in [course.startTime, course.endTime] {
                        if let minute = WidgetDisplayState.minutes(text) {
                            marks.insert(atMinute(minute, of: day, calendar: calendar))
                        }
                    }
                }
            }
            // 末课结束与 17:00 取大者（切明天点）；无课时即 17:00
            let lastEnd = dayCourses.courses.map { WidgetDisplayState.minutes($0.endTime) ?? 0 }.max() ?? 0
            let forecast = max(lastEnd, WidgetDisplayState.forecastFloorMinute)
            marks.insert(atMinute(forecast, of: day, calendar: calendar))
            // 次日 00:05 切日 entry
            if let roll = calendar.date(byAdding: .day, value: 1, to: day) {
                marks.insert(atMinute(Self.dayRollMinute, of: roll, calendar: calendar))
            }
        }

        // 2. 进行中课程时段的分钟粒度 entry（倒计时推进，对齐 Android 分钟级刷新）
        for dayOffset in 0..<max(horizonDays, 1) {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: dayStart),
                  let courses = courses(on: day, snapshot: snapshot, timeZone: timeZone) else { continue }
            for course in courses {
                guard let start = WidgetDisplayState.minutes(course.startTime),
                      let end = WidgetDisplayState.minutes(course.endTime),
                      end > start else { continue }
                let startDate = atMinute(start, of: day, calendar: calendar)
                let endDate = atMinute(end, of: day, calendar: calendar)
                // 只对「date 之后仍有效」的进行中时段逐分钟铺 entry
                var tick = startDate < date ? date : startDate
                while tick < endDate {
                    marks.insert(tick)
                    guard let next = calendar.date(byAdding: .minute, value: 1, to: tick) else { break }
                    tick = next
                }
            }
        }

        // 3. 每个关键点计算状态 → entry（排序、过滤过去、单调、截断保近端）
        // marks 已含 date，排序后首 entry 必为当前时刻状态
        let sortedMarks = marks.filter { $0 >= date }.sorted()
        return sortedMarks.prefix(Self.maxEntries).map { mark in
            Entry(date: mark, state: WidgetDisplayState.compute(
                snapshot: snapshot, date: mark, timeZone: timeZone
            ))
        }
    }

    /// 某日某分钟的时刻。
    private static func atMinute(_ minute: Int, of day: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: DateComponents(minute: minute), to: calendar.startOfDay(for: day)) ?? day
    }

    /// 某日命中 weekRule 的课程（复用 WidgetDisplayState 同源查询，避免逻辑漂移）。
    private static func courses(
        on day: Date, snapshot: WidgetSnapshot, timeZone: TimeZone
    ) -> [(id: Int64, startTime: String, endTime: String)]? {
        WidgetDisplayState.courses(on: day, snapshot: snapshot, timeZone: timeZone)?
            .map { ($0.id, $0.startTime, $0.endTime) }
    }
}
