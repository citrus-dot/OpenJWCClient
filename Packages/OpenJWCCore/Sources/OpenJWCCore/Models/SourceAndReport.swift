import Foundation
import GRDB

// MARK: - notices

public struct NoticeRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "notices"

    public var id: String
    public var sourceId: String?
    public var label: String
    public var title: String
    /// 毫秒 epoch（两端一致）。
    public var publishedAt: Int64
    /// yyyy-MM-dd。
    public var publishedDay: String
    public var detailUrl: String
    public var isPage: Bool
    public var content: String?
    public var contentVersion: Int
    public var attachments: JSONStringList?
    public var fetchedAt: Int64
    public var notified: Bool
    public var favorite: Bool

    public init(
        id: String, sourceId: String?, label: String, title: String,
        publishedAt: Int64, publishedDay: String, detailUrl: String, isPage: Bool,
        content: String?, contentVersion: Int, attachments: JSONStringList?,
        fetchedAt: Int64, notified: Bool, favorite: Bool
    ) {
        self.id = id
        self.sourceId = sourceId
        self.label = label
        self.title = title
        self.publishedAt = publishedAt
        self.publishedDay = publishedDay
        self.detailUrl = detailUrl
        self.isPage = isPage
        self.content = content
        self.contentVersion = contentVersion
        self.attachments = attachments
        self.fetchedAt = fetchedAt
        self.notified = notified
        self.favorite = favorite
    }
}

// MARK: - notice_sources

public struct NoticeSourceRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "notice_sources"

    public var id: String
    public var name: String
    public var version: String
    public var origin: String
    public var scriptFile: String?
    public var domains: JSONStringList
    public var labels: JSONStringList
    public var scheduleMinutes: Int
    public var subscribed: Bool
    public var lastRunAt: Int64?
    public var lastCount: Int
    public var lastError: String?

    public init(
        id: String, name: String, version: String, origin: String, scriptFile: String?,
        domains: JSONStringList, labels: JSONStringList, scheduleMinutes: Int,
        subscribed: Bool, lastRunAt: Int64?, lastCount: Int, lastError: String?
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.origin = origin
        self.scriptFile = scriptFile
        self.domains = domains
        self.labels = labels
        self.scheduleMinutes = scheduleMinutes
        self.subscribed = subscribed
        self.lastRunAt = lastRunAt
        self.lastCount = lastCount
        self.lastError = lastError
    }
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
