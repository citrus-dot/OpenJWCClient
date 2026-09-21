import Foundation
import GRDB

// MARK: - notices

struct NoticeRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "notices"

    var id: String
    var sourceId: String?
    var label: String
    var title: String
    /// 毫秒 epoch（两端一致）。
    var publishedAt: Int64
    /// yyyy-MM-dd。
    var publishedDay: String
    var detailUrl: String
    var isPage: Bool
    var content: String?
    var contentVersion: Int
    var attachments: JSONStringList?
    var fetchedAt: Int64
    var notified: Bool
    var favorite: Bool
}

// MARK: - notice_sources

struct NoticeSourceRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "notice_sources"

    var id: String
    var name: String
    var version: String
    var origin: String
    var scriptFile: String?
    var domains: JSONStringList
    var labels: JSONStringList
    var scheduleMinutes: Int
    var subscribed: Bool
    var lastRunAt: Int64?
    var lastCount: Int
    var lastError: String?
}

// MARK: - daily_reports

enum DailyReportStatus: String {
    case running
    case completed
    case failed
}

struct DailyReportRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "daily_reports"

    /// yyyy-MM-dd，主键。
    var day: String
    var status: String
    var content: String
    var sourceCount: Int
    var error: String?
    var updatedAt: Int64
}
