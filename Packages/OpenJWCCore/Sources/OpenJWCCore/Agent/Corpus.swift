import Foundation
import GRDB

// MARK: - 语料/课表/日报 只读协议（对齐 Android data/repository/NoticeCorpus 等）

/// 栏目及其条数。
public struct CorpusLabelCount: Equatable, Sendable {
    public var label: String
    public var count: Int

    public init(label: String, count: Int) {
        self.label = label
        self.count = count
    }
}

/// 语料目录概览（system 元数据用）。
public struct CorpusCatalog: Equatable, Sendable {
    public var total: Int
    public var firstDay: String?
    public var lastDay: String?

    public init(total: Int, firstDay: String?, lastDay: String?) {
        self.total = total
        self.firstDay = firstDay
        self.lastDay = lastDay
    }
}

/// Agent 只读的本地资讯语料能力。
public protocol NoticeCorpus: Sendable {
    func searchNotices(
        query: String, label: String, sourceId: String?, fromDay: String, toDay: String,
        favoriteOnly: Bool, relevance: Bool, limit: Int, offset: Int
    ) async throws -> [NoticeRecord]
    func countNotices(
        query: String, label: String, sourceId: String?, fromDay: String, toDay: String,
        favoriteOnly: Bool
    ) async throws -> Int
    func findNotice(id: String) async throws -> NoticeRecord?
    func corpusLabels() async throws -> [CorpusLabelCount]
    func subscribedSources() async throws -> [NoticeSourceRecord]
    func corpusCatalog() async throws -> CorpusCatalog
}

/// 课表快照（Agent 工具视图，含学期计算结果）。
public struct TimetableSnapshot: Sendable {
    public var id: Int64
    public var name: String
    public var startDate: String
    public var totalWeeks: Int
    public var currentWeek: Int?
    public var isCurrent: Bool
    public var courses: [AgentCourse]

    public init(
        id: Int64, name: String, startDate: String, totalWeeks: Int,
        currentWeek: Int?, isCurrent: Bool, courses: [AgentCourse]
    ) {
        self.id = id
        self.name = name
        self.startDate = startDate
        self.totalWeeks = totalWeeks
        self.currentWeek = currentWeek
        self.isCurrent = isCurrent
        self.courses = courses
    }
}

/// 课表课程（Agent 视图：周次已解析为集合）。
public struct AgentCourse: Sendable {
    public var name: String
    public var teacher: String
    public var location: String
    /// 1=周一 … 7=周日。
    public var dayOfWeek: Int
    public var startPeriod: Int
    public var duration: Int
    public var weeks: Set<Int>
    public var note: String

    public init(
        name: String, teacher: String, location: String, dayOfWeek: Int,
        startPeriod: Int, duration: Int, weeks: Set<Int>, note: String
    ) {
        self.name = name
        self.teacher = teacher
        self.location = location
        self.dayOfWeek = dayOfWeek
        self.startPeriod = startPeriod
        self.duration = duration
        self.weeks = weeks
        self.note = note
    }
}

/// 课表读取能力；为 nil 时不暴露课表工具。
public protocol TimetableSource: Sendable {
    func timetables() async throws -> [TimetableSnapshot]
    func currentTimetable() async throws -> TimetableSnapshot?
}

/// 日报只读能力；为 nil 时不暴露日报工具。
public protocol DailyReportSource: Sendable {
    func completedReport(day: String) async throws -> String?
}

// MARK: - GRDB 默认实现

/// 基于阶段 1 DAO 的默认语料实现。
public struct GrdbNoticeCorpus: NoticeCorpus {
    private let noticeDao: NoticeDao
    private let sourceDao: SourceDao

    public init(db: any DatabaseWriter) {
        self.noticeDao = NoticeDao(db: db)
        self.sourceDao = SourceDao(db: db)
    }

    public func searchNotices(
        query: String, label: String, sourceId: String?, fromDay: String, toDay: String,
        favoriteOnly: Bool, relevance: Bool, limit: Int, offset: Int
    ) async throws -> [NoticeRecord] {
        try await noticeDao.searchNotices(NoticeSearchQuery(
            query: query, label: label, sourceId: sourceId, fromDay: fromDay, toDay: toDay,
            favoriteOnly: favoriteOnly ? 1 : 0, relevance: relevance ? 1 : 0,
            limit: limit, offset: offset
        ))
    }

    public func countNotices(
        query: String, label: String, sourceId: String?, fromDay: String, toDay: String,
        favoriteOnly: Bool
    ) async throws -> Int {
        try await noticeDao.countNotices(
            query: query, label: label, sourceId: sourceId,
            fromDay: fromDay, toDay: toDay, favoriteOnly: favoriteOnly ? 1 : 0
        )
    }

    public func findNotice(id: String) async throws -> NoticeRecord? {
        try await noticeDao.findById(id: id)
    }

    public func corpusLabels() async throws -> [CorpusLabelCount] {
        try await noticeDao.labelCounts().map { CorpusLabelCount(label: $0.label, count: $0.labelCount) }
    }

    public func subscribedSources() async throws -> [NoticeSourceRecord] {
        try await sourceDao.getSubscribed()
    }

    public func corpusCatalog() async throws -> CorpusCatalog {
        let total = try await noticeDao.totalCount()
        guard total > 0 else { return CorpusCatalog(total: 0, firstDay: nil, lastDay: nil) }
        return CorpusCatalog(
            total: total,
            firstDay: try await noticeDao.minDay(),
            lastDay: try await noticeDao.maxDay()
        )
    }
}

/// 基于 DAO 的课表读取实现（学期周次在此解析）。
public struct GrdbTimetableSource: TimetableSource {
    private let dao: TimetableDao
    private let timeZone: TimeZone

    public init(db: any DatabaseWriter, timeZone: TimeZone = .current) {
        self.dao = TimetableDao(db: db)
        self.timeZone = timeZone
    }

    public func timetables() async throws -> [TimetableSnapshot] {
        let tables = try await dao.allTables()
        var snapshots: [TimetableSnapshot] = []
        for table in tables {
            snapshots.append(try await snapshot(of: table))
        }
        return snapshots
    }

    public func currentTimetable() async throws -> TimetableSnapshot? {
        guard let table = try await dao.currentTable() else { return nil }
        return try await snapshot(of: table)
    }

    private func snapshot(of table: TableMetadataRecord) async throws -> TimetableSnapshot {
        let courses = try await dao.courses(tableId: table.id ?? 0)
        let config = table.semesterConfig
        let today = Date()
        return TimetableSnapshot(
            id: table.id ?? 0,
            name: table.tableName,
            startDate: config.startDate,
            totalWeeks: config.weeks,
            currentWeek: Self.currentWeek(startDate: config.startDate, weeks: config.weeks, today: today, timeZone: timeZone),
            isCurrent: table.isCurrent,
            courses: courses.map { course in
                AgentCourse(
                    name: course.name, teacher: course.teacher, location: course.location,
                    dayOfWeek: course.dayOfWeek, startPeriod: course.startPeriod,
                    duration: course.duration, weeks: course.weekRule.value, note: course.note
                )
            }
        )
    }

    /// 某日期是学期第几周；不在学期内返回 nil（对齐 Android weekOf）。
    public static func currentWeek(startDate: String, weeks: Int, today: Date, timeZone: TimeZone) -> Int? {
        guard weeks > 0, let start = Self.parseDay(startDate) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2 // 周一
        guard let startMonday = calendar.dateInterval(of: .weekOfYear, for: start)?.start,
              let endSunday = calendar.date(byAdding: .day, value: weeks * 7 - 1, to: startMonday),
              today >= startMonday, today <= endSunday else {
            return nil
        }
        let days = calendar.dateComponents([.day], from: startMonday, to: today).day ?? 0
        return min(max(days / 7 + 1, 1), weeks)
    }

    static func parseDay(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: value)
    }
}

/// 基于 DAO 的日报读取实现。
public struct GrdbDailyReportSource: DailyReportSource {
    private let dao: DailyReportDao

    public init(db: any DatabaseWriter) {
        self.dao = DailyReportDao(db: db)
    }

    public func completedReport(day: String) async throws -> String? {
        try await dao.get(day: day).flatMap { record in
            record.status == "completed" ? record.content : nil
        }
    }
}
