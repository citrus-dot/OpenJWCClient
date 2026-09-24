import Foundation

/// 小组件显示状态纯函数（design D-6）：逐条直译 Android `WidgetModels` 显示算法。
/// 输入快照 + 时刻 → 该时刻的显示状态；小组件视图与时间线 builder 共用。
public struct WidgetDisplayState: Equatable, Sendable {
    /// 最多显示课程数（对齐 Android MAX_COURSES）。
    public static let maxCourses = 2
    /// 切明天固定下界：17:00（当日分钟数，对齐 Android）。
    static let forecastFloorMinute = 17 * 60

    /// true = 明天预告模式（当前时刻 ≥ max(17:00, 今日末课结束)）。
    public var showsTomorrow: Bool
    /// 学期第几周（不在学期内为 nil；显示「第 N 周」）。
    public var weekNumber: Int?
    /// 课程卡（最多 2 门，按上课时间排序）。
    public var courses: [Course]
    /// MAX_COURSES 之外的剩余课程（systemLarge 完整列表用；Small/Medium 不消费）。
    public var moreCourses: [Course]
    /// 空态文案：「今天没有课」/「今日课程已结束」/「明天没有课」；nil = 有课。
    public var emptyMessage: String?

    public init(
        showsTomorrow: Bool, weekNumber: Int?,
        courses: [Course], moreCourses: [Course] = [],
        emptyMessage: String?
    ) {
        self.showsTomorrow = showsTomorrow
        self.weekNumber = weekNumber
        self.courses = courses
        self.moreCourses = moreCourses
        self.emptyMessage = emptyMessage
    }

    public struct Course: Equatable, Sendable {
        public var id: Int64
        public var name: String
        /// HH:mm（节次起止）。
        public var startTime: String
        public var endTime: String
        /// 「第 X-Y 节」或「第 X 节」。
        public var periodText: String
        public var location: String
        public var teacher: String
        /// ARGB 数值（可能为负，UI 层转换）。
        public var color: Int64
        /// 下课倒计时（分钟，向上取整不为负）：进行中课程有值；刚结束保留的课为 0；未开始为 nil。
        public var countdownMinutes: Int?

        public init(
            id: Int64, name: String, startTime: String, endTime: String,
            periodText: String, location: String, teacher: String,
            color: Int64, countdownMinutes: Int?
        ) {
            self.id = id
            self.name = name
            self.startTime = startTime
            self.endTime = endTime
            self.periodText = periodText
            self.location = location
            self.teacher = teacher
            self.color = color
            self.countdownMinutes = countdownMinutes
        }
    }

    /// 计算某时刻的显示状态（timeZone 当地墙钟语义）。
    public static func compute(
        snapshot: WidgetSnapshot, date: Date, timeZone: TimeZone = .current
    ) -> WidgetDisplayState {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let comps = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let secondOfDay = minuteOfDay * 60 + (comps.second ?? 0)

        // 切明天判定：current ≥ max(17:00, 今日末课结束)（对齐 Android forecastMinute）
        let lastEnd = todayLastEndMinute(snapshot: snapshot, day: date, timeZone: timeZone)
        if minuteOfDay >= max(Self.forecastFloorMinute, lastEnd) {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            let tomorrowCourses = courses(on: tomorrow, snapshot: snapshot, timeZone: timeZone) ?? []
            let mapped = mapCourses(tomorrowCourses, minuteOfDay: nil, latestStart: nil)
            return WidgetDisplayState(
                showsTomorrow: true,
                weekNumber: weekOf(snapshot: snapshot, day: tomorrow, timeZone: timeZone),
                courses: mapped.main,
                moreCourses: mapped.more,
                emptyMessage: tomorrowCourses.isEmpty ? "明天没有课" : nil
            )
        }

        // 今天模式：剩余过滤（直译 Android）
        // endMinute > current || start == latestStartedMinute —— 刚结束的最后一门课
        // 保留（倒计时 0）至下一节开始
        guard let todayCourses = courses(on: date, snapshot: snapshot, timeZone: timeZone) else {
            return WidgetDisplayState(
                showsTomorrow: false,
                weekNumber: nil, courses: [], emptyMessage: "今天没有课"
            )
        }
        guard !todayCourses.isEmpty else {
            return WidgetDisplayState(
                showsTomorrow: false,
                weekNumber: weekOf(snapshot: snapshot, day: date, timeZone: timeZone),
                courses: [], emptyMessage: "今天没有课"
            )
        }
        // latestStartedMinute = 已开始课程（start ≤ current）的最大 start：
        // 刚结束的课保留（倒计时 0）至下一门课开始（下节开始后 latestStarted 前移，
        // 旧课自动让位——spec「刚结束课程保留至下节课开始」的字面语义）
        let latestStart = todayCourses
            .compactMap { Self.minutes($0.startTime) }
            .filter { $0 <= minuteOfDay }
            .max()
        let remaining = todayCourses.filter { course in
            guard let start = Self.minutes(course.startTime),
                  let end = Self.minutes(course.endTime) else { return false }
            return end > minuteOfDay || start == latestStart
        }
        guard !remaining.isEmpty else {
            return WidgetDisplayState(
                showsTomorrow: false,
                weekNumber: weekOf(snapshot: snapshot, day: date, timeZone: timeZone),
                courses: [], emptyMessage: "今日课程已结束"
            )
        }
        let mapped = mapCourses(remaining, minuteOfDay: minuteOfDay, latestStart: latestStart, secondOfDay: secondOfDay)
        return WidgetDisplayState(
            showsTomorrow: false,
            weekNumber: weekOf(snapshot: snapshot, day: date, timeZone: timeZone),
            courses: mapped.main,
            moreCourses: mapped.more,
            emptyMessage: nil
        )
    }

    // MARK: - 映射（排序 + 截断 + 倒计时）

    /// 映射为显示课程：按上课时间排序、截前 MAX_COURSES 门、计算倒计时；
    /// 其余进 moreCourses（systemLarge 完整列表）。
    private static func mapCourses(
        _ courses: [Course], minuteOfDay: Int?, latestStart: Int?, secondOfDay: Int = 0
    ) -> (main: [Course], more: [Course]) {
        let sorted = courses.sorted {
            (Self.minutes($0.startTime) ?? 0) < (Self.minutes($1.startTime) ?? 0)
        }
        let mapped = sorted.map { course -> Course in
            var countdown: Int?
            if let minuteOfDay,
               let start = Self.minutes(course.startTime),
               let end = Self.minutes(course.endTime) {
                if start <= minuteOfDay, minuteOfDay < end {
                    // 进行中：剩余秒向上取整（分钟 entry 对齐整分时差值即 ceil 结果）
                    let remainingSeconds = end * 60 - secondOfDay
                    countdown = max(Int((Double(remainingSeconds) / 60.0).rounded(.up)), 0)
                } else if end <= minuteOfDay, start == latestStart {
                    countdown = 0 // 刚结束保留：倒计时 0（对齐 Android）
                }
            }
            return Course(
                id: course.id, name: course.name,
                startTime: course.startTime, endTime: course.endTime,
                periodText: course.periodText, location: course.location,
                teacher: course.teacher, color: course.color,
                countdownMinutes: countdown
            )
        }
        return (Array(mapped.prefix(Self.maxCourses)), Array(mapped.dropFirst(Self.maxCourses)))
    }

    // MARK: - 日期工具

    /// 某日命中 weekRule 的课程（已映射）；不在学期内返回 nil（builder 与时间线共用）。
    static func courses(
        on day: Date, snapshot: WidgetSnapshot, timeZone: TimeZone
    ) -> [Course]? {
        guard let week = weekOf(snapshot: snapshot, day: day, timeZone: timeZone) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let weekday = calendar.component(.weekday, from: day)
        let isoDay = weekday == 1 ? 7 : weekday - 1

        return snapshot.courses.filter { $0.dayOfWeek == isoDay && $0.weekRule.contains(week) }.map { course in
            let startIndex = course.startPeriod - 1
            let endIndex = course.startPeriod + course.duration - 2
            let startText = snapshot.periods.indices.contains(startIndex) ? snapshot.periods[startIndex].start : ""
            let endText = snapshot.periods.indices.contains(endIndex) ? snapshot.periods[endIndex].end : ""
            let periodText = course.duration > 1
                ? "第\(course.startPeriod)-\(course.startPeriod + course.duration - 1)节"
                : "第\(course.startPeriod)节"
            return Course(
                id: course.id, name: course.name,
                startTime: startText, endTime: endText,
                periodText: periodText, location: course.location,
                teacher: course.teacher, color: course.color,
                countdownMinutes: nil
            )
        }
    }

    private static func todayLastEndMinute(
        snapshot: WidgetSnapshot, day: Date, timeZone: TimeZone
    ) -> Int {
        guard let courses = courses(on: day, snapshot: snapshot, timeZone: timeZone) else {
            return 0
        }
        return courses.compactMap { Self.minutes($0.endTime) }.max() ?? 0
    }

    /// 某日是学期第几周（复用 GrdbTimetableSource 同一算法，语义与课表页一致）。
    private static func weekOf(
        snapshot: WidgetSnapshot, day: Date, timeZone: TimeZone
    ) -> Int? {
        GrdbTimetableSource.currentWeek(
            startDate: snapshot.startDate, weeks: snapshot.totalWeeks,
            today: day, timeZone: timeZone
        )
    }

    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}
