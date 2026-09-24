import Foundation

/// 课程提醒计划纯函数（design D-4）：课表快照 + 当前时刻 → 未来窗口内的提醒计划列表。
/// app 层只做注册（UNTimeIntervalNotificationTrigger），全部语义在此锁定并可单测：
/// 提前量固定 10 分钟（对齐 Android REMINDER_LEAD_MILLIS）、窗口 14 天（64 条 pending 核算收缩）、
/// 稳定 id 确定性派生（前缀过滤全量取消）、超 64 条保近端。
public enum CourseReminderPlan {

    public struct Item: Equatable, Sendable {
        /// 稳定 id：`course-<tableId>-<courseId>-<week>-<classStartMillis>`（确定性，可前缀过滤）。
        public var identifier: String
        public var fireDate: Date
        /// 「课程还有 10 分钟开始」。
        public var title: String
        /// 「课名 · 时间段 · 教室 · 教师」（空字段省略对应段，对齐 Android 四段格式）。
        public var body: String
        public var courseName: String
        public var timeText: String
        public var classroom: String
        public var teacher: String

        public static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.identifier == rhs.identifier && lhs.fireDate == rhs.fireDate
                && lhs.title == rhs.title && lhs.body == rhs.body
        }
    }

    /// 提前量（分钟，固定不可配——spec「通知权限申请/课程提醒通知」锁定口径）。
    public static let leadMinutes = 10
    /// 排程窗口（天）：64 条 pending 上限核算（D-4 表），对齐 Android 21 天的收缩值。
    public static let windowDays = 14
    /// iOS 待发通知硬上限。
    public static let maxPending = 64

    /// 构建提醒计划。
    /// - Parameters:
    ///   - snapshot: 课表快照（表元数据 + 节次 + 全部课程）。
    ///   - now: 当前时刻；fireDate ∈ (now, now + windowDays] 才保留。
    ///   - timeZone: 本地时区（上课时刻按当地墙钟计算）。
    ///   - windowDays/leadMinutes/limit: 默认对齐常量（参数化供测试）。
    public static func build(
        snapshot: WidgetSnapshot,
        now: Date,
        timeZone: TimeZone = .current,
        windowDays: Int = CourseReminderPlan.windowDays,
        leadMinutes: Int = CourseReminderPlan.leadMinutes,
        limit: Int = CourseReminderPlan.maxPending
    ) -> [Item] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let windowEnd = now.addingTimeInterval(Double(windowDays) * 86_400)
        var items: [Item] = []

        // 逐日历日展开候选（从今天到窗口末日；已过时刻由 fireDate > now 过滤）
        for dayOffset in 0...windowDays {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: day)
            // Calendar.weekday: 周日=1…周六=7 → ISO 星期（周一=1…周日=7）
            let isoDay = weekday == 1 ? 7 : weekday - 1
            // 该日期是学期第几周（不在学期内的日期无课）
            guard let week = GrdbTimetableSource.currentWeek(
                startDate: snapshot.startDate, weeks: snapshot.totalWeeks,
                today: day, timeZone: timeZone
            ) else { continue }

            for course in snapshot.courses where course.dayOfWeek == isoDay {
                guard course.weekRule.contains(week) else { continue }
                // 节次 → 当天时刻（startPeriod 1-based；duration 连续节）
                let startIndex = course.startPeriod - 1
                let endIndex = course.startPeriod + course.duration - 2
                guard snapshot.periods.indices.contains(startIndex),
                      snapshot.periods.indices.contains(endIndex),
                      let startMinute = Self.minutes(snapshot.periods[startIndex].start),
                      let endMinute = Self.minutes(snapshot.periods[endIndex].end) else {
                    continue
                }

                var comps = calendar.dateComponents([.year, .month, .day], from: day)
                comps.hour = startMinute / 60
                comps.minute = startMinute % 60
                guard let classStart = calendar.date(from: comps) else { continue }
                let fireDate = classStart.addingTimeInterval(TimeInterval(-leadMinutes * 60))
                guard fireDate > now, fireDate <= windowEnd else { continue }

                let classStartMillis = Int64(classStart.timeIntervalSince1970 * 1000)
                let timeText = "\(snapshot.periods[startIndex].start)-\(snapshot.periods[endIndex].end)"
                let body = [course.name, timeText, course.location, course.teacher]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                items.append(Item(
                    identifier: "course-\(snapshot.tableId)-\(course.id)-\(week)-\(classStartMillis)",
                    fireDate: fireDate,
                    title: "课程还有 \(leadMinutes) 分钟开始",
                    body: body,
                    courseName: course.name,
                    timeText: timeText,
                    classroom: course.location,
                    teacher: course.teacher
                ))
            }
        }

        // 按上课时刻升序，超上限保近端（远端靠下次启动滚动重排补入）
        items.sort { $0.fireDate < $1.fireDate }
        return items.count > limit ? Array(items.prefix(limit)) : items
    }

    private static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}
