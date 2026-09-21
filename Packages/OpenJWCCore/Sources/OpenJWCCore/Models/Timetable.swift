import Foundation
import GRDB

/// 学期配置：JSON 文本列存储，结构对齐 Android `SemesterConfig`（kotlinx 序列化字段名）。
/// 时间以字符串承载（startDate=ISO 日期、Period.start/end=HH:mm），两端无时区歧义。
struct SemesterConfig: Codable, DatabaseValueConvertible, Equatable {
    var startDate: String
    var weeks: Int
    var visibleDays: Set<Int>
    var periods: [Period]

    struct Period: Codable, Equatable {
        var index: Int
        var start: String
        var end: String
    }

    var databaseValue: DatabaseValue {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{}".databaseValue
        }
        return text.databaseValue
    }

    static func from(databaseValue: DatabaseValue) -> Self? {
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

struct TableMetadataRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "table_metadata"

    var id: Int64?
    var tableName: String
    var semesterConfig: SemesterConfig
    var isCurrent: Bool
}

// MARK: - courses

struct CourseRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "courses"

    var id: Int64?
    var tableId: Int64
    var name: String
    var teacher: String
    var location: String
    /// ISO 星期：周一=1 … 周日=7（两端一致）。
    var dayOfWeek: Int
    var startPeriod: Int
    var duration: Int
    /// ARGB 数值（与 Android `Color.toArgb()` 的 Int 同一位模式，可能为负；UI 层再转 SwiftUI Color）。
    var color: Int64
    var weekRule: JSONIntSet
    var note: String
}
