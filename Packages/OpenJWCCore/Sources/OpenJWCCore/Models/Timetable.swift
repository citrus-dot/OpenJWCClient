import Foundation
import GRDB

/// 学期配置：JSON 文本列存储，结构对齐 Android `SemesterConfig`（kotlinx 序列化字段名）。
/// 时间以字符串承载（startDate=ISO 日期、Period.start/end=HH:mm），两端无时区歧义。
public struct SemesterConfig: Codable, DatabaseValueConvertible, Equatable, Sendable {
    public var startDate: String
    public var weeks: Int
    public var visibleDays: Set<Int>
    public var periods: [Period]

    public struct Period: Codable, Equatable, Sendable {
        public var index: Int
        public var start: String
        public var end: String

        public init(index: Int, start: String, end: String) {
            self.index = index
            self.start = start
            self.end = end
        }
    }

    public init(startDate: String, weeks: Int, visibleDays: Set<Int>, periods: [Period]) {
        self.startDate = startDate
        self.weeks = weeks
        self.visibleDays = visibleDays
        self.periods = periods
    }

    public var databaseValue: DatabaseValue {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{}".databaseValue
        }
        return text.databaseValue
    }

    public static func from(databaseValue: DatabaseValue) -> Self? {
        guard let text = databaseValue.storage.value as? String,
              let data = text.data(using: .utf8),
              var config = try? JSONDecoder().decode(SemesterConfig.self, from: data) else {
            // 解码失败回退空配置（Android 端此路径会返回 null；字段非空列，iOS 选择不崩）
            return SemesterConfig(startDate: "", weeks: 0, visibleDays: [], periods: [])
        }
        if config.visibleDays.isEmpty {
            config.visibleDays = [1, 2, 3, 4, 5, 6, 7]
        }
        return config
    }
}

// MARK: - table_metadata

public struct TableMetadataRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "table_metadata"

    public var id: Int64?
    public var tableName: String
    public var semesterConfig: SemesterConfig
    public var isCurrent: Bool

    public init(id: Int64? = nil, tableName: String, semesterConfig: SemesterConfig, isCurrent: Bool) {
        self.id = id
        self.tableName = tableName
        self.semesterConfig = semesterConfig
        self.isCurrent = isCurrent
    }
}

// MARK: - courses

public struct CourseRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "courses"

    public var id: Int64?
    public var tableId: Int64
    public var name: String
    public var teacher: String
    public var location: String
    /// ISO 星期：周一=1 … 周日=7（两端一致）。
    public var dayOfWeek: Int
    public var startPeriod: Int
    public var duration: Int
    /// ARGB 数值（与 Android `Color.toArgb()` 的 Int 同一位模式，可能为负；UI 层再转 SwiftUI Color）。
    public var color: Int64
    public var weekRule: JSONIntSet
    public var note: String

    public init(
        id: Int64? = nil, tableId: Int64, name: String, teacher: String, location: String,
        dayOfWeek: Int, startPeriod: Int, duration: Int, color: Int64,
        weekRule: JSONIntSet, note: String
    ) {
        self.id = id
        self.tableId = tableId
        self.name = name
        self.teacher = teacher
        self.location = location
        self.dayOfWeek = dayOfWeek
        self.startPeriod = startPeriod
        self.duration = duration
        self.color = color
        self.weekRule = weekRule
        self.note = note
    }
}
