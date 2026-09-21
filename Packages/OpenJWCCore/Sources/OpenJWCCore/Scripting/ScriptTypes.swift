import Foundation

// MARK: - 脚本清单（对齐 Android ScriptManifest）

/// 数据源脚本清单，来自脚本头部注释（`// @id xxx` 等）。
public struct ScriptManifest: Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var scheduleMinutes: Int
    public var domains: [String]
    public var labels: [String]

    public init(
        id: String, name: String, version: String,
        scheduleMinutes: Int, domains: [String], labels: [String]
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.scheduleMinutes = scheduleMinutes
        self.domains = domains
        self.labels = labels
    }
}

public enum ScriptManifestParser {
    /// WorkManager/BGTask 周期最短 15 分钟。
    public static let minScheduleMinutes = 15
    private static let defaultScheduleMinutes = 360

    /// 解析脚本头部注释；无 @id 时返回 nil。
    public static func parse(_ script: String) -> ScriptManifest? {
        var fields: [String: String] = [:]
        for rawLine in script.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("//") || line.hasPrefix("#") else { continue }
            var body = line
            body.removeFirst(min(2, body.count))
            body = body.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("#") {
                body.removeFirst()
                body = body.trimmingCharacters(in: .whitespaces)
            }
            guard body.hasPrefix("@") else { continue }
            body.removeFirst()
            guard let space = body.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == ":" }),
                  space != body.startIndex else { continue }
            let key = String(body[body.startIndex..<space]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(body[body.index(after: space)...])
                .trimmingCharacters(in: .whitespaces)
            while value.hasPrefix(":") {
                value.removeFirst()
                value = value.trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty && !value.isEmpty { fields[key] = value }
        }

        guard let id = fields["id"] else { return nil }
        let schedule = fields["schedule"].flatMap(Int.init)
            .map { max($0, minScheduleMinutes) } ?? defaultScheduleMinutes
        return ScriptManifest(
            id: id,
            name: fields["name"] ?? id,
            version: fields["version"] ?? "1.0.0",
            scheduleMinutes: schedule,
            domains: splitList(fields["domains"]),
            labels: splitList(fields["labels"])
        )
    }

    private static func splitList(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .split(whereSeparator: { ",， |".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - 运行参数与结果（对齐 Android ScriptApi.kt 数据类）

/// 一次脚本运行的参数（由 App 注入）。
public struct ScriptRunParams: Sendable {
    public var crawlDaysGap: Int
    public var knownIds: [String]

    public init(crawlDaysGap: Int = 200, knownIds: [String] = []) {
        self.crawlDaysGap = crawlDaysGap
        self.knownIds = knownIds
    }
}

/// 脚本返回的单条资讯。字段名与脚本契约一致（snake_case）。
public struct ScriptNotice: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var title: String
    public var date: String
    public var detailUrl: String
    public var isPage: Bool
    public var contentText: String?
    public var attachments: [String]?

    public init(
        id: String = "", label: String = "", title: String = "", date: String = "",
        detailUrl: String = "", isPage: Bool = true, contentText: String? = nil,
        attachments: [String]? = nil
    ) {
        self.id = id
        self.label = label
        self.title = title
        self.date = date
        self.detailUrl = detailUrl
        self.isPage = isPage
        self.contentText = contentText
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, title, date
        case detailUrl = "detail_url"
        case isPage = "is_page"
        case contentText = "content_text"
        case attachments
    }
}

/// 一次脚本运行的完整结果（对齐 Android ScriptOutcome）。
public struct ScriptOutcome: Equatable, Sendable {
    public var notices: [ScriptNotice]
    public var scanned: Int
    public var skipped: Int
    public var failed: Int
    public var noContent: Int
    public var restricted: Int
    public var skippedOld: Int
    public var skippedDuplicate: Int
    public var skippedKnown: Int
    public var warnings: [String]

    public init(
        notices: [ScriptNotice] = [], scanned: Int = 0, skipped: Int = 0, failed: Int = 0,
        noContent: Int = 0, restricted: Int = 0, skippedOld: Int = 0,
        skippedDuplicate: Int = 0, skippedKnown: Int = 0, warnings: [String] = []
    ) {
        self.notices = notices
        self.scanned = scanned
        self.skipped = skipped
        self.failed = failed
        self.noContent = noContent
        self.restricted = restricted
        self.skippedOld = skippedOld
        self.skippedDuplicate = skippedDuplicate
        self.skippedKnown = skippedKnown
        self.warnings = warnings
    }
}

// MARK: - 错误

public enum ScriptError: Error, CustomStringConvertible {
    /// 脚本执行超时（worker 已放弃）。
    case timeout
    /// 违反沙箱限制（域名白名单 / 调用次数 / 字节上限）。
    case sandbox(String)
    /// 脚本执行失败。
    case execution(String)

    public var description: String {
        switch self {
        case .timeout: return "脚本执行超时"
        case .sandbox(let msg): return "沙箱限制：\(msg)"
        case .execution(let msg): return "脚本执行失败：\(msg)"
        }
    }
}

// MARK: - 沙箱（对齐 Android ScriptSandbox）

/// 单次脚本执行的沙箱限制。JSC 同步执行在单 worker 线程内，无需加锁。
public final class ScriptSandbox: @unchecked Sendable {
    public let allowedDomains: Set<String>
    public let timeoutMs: Int
    public let maxHttpCalls: Int
    public let maxBytes: Int

    private var httpCalls = 0
    private var bytes = 0

    public init(
        allowedDomains: Set<String> = [],
        timeoutMs: Int = 60_000,
        maxHttpCalls: Int = 200,
        maxBytes: Int = 8 * 1024 * 1024
    ) {
        self.allowedDomains = allowedDomains
        self.timeoutMs = timeoutMs
        self.maxHttpCalls = maxHttpCalls
        self.maxBytes = maxBytes
    }

    public func checkUrl(_ url: String) throws {
        guard let host = URL(string: url)?.host?.lowercased() else {
            throw ScriptError.sandbox("非法 URL: \(url)")
        }
        if allowedDomains.isEmpty { return }
        let allowed = allowedDomains.contains { domain in
            let d = domain.lowercased()
            return host == d || host.hasSuffix(".\(d)")
        }
        if !allowed {
            throw ScriptError.sandbox("域名不在白名单: \(host)")
        }
    }

    public func onHttpCall() throws {
        httpCalls += 1
        if httpCalls > maxHttpCalls {
            throw ScriptError.sandbox("HTTP 调用次数超过上限 (\(maxHttpCalls))")
        }
    }

    public func onBytes(_ count: Int) throws {
        bytes += count
        if bytes > maxBytes {
            throw ScriptError.sandbox("下载数据超过上限")
        }
    }
}
