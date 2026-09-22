import Foundation

/// 格言（对齐 Android Motto.kt）：在线一言或本地自定义。
public struct Motto: Codable, Equatable, Sendable {
    public var text: String
    public var author: String?
    public var source: String?
    /// 在线一言的永久链接；本地模式为 nil。
    public var permalink: String?
    /// 缓存日（yyyy-MM-dd；本地模式不参与缓存）。
    public var date: String

    public init(text: String, author: String? = nil, source: String? = nil, permalink: String? = nil, date: String = "") {
        self.text = text
        self.author = author
        self.source = source
        self.permalink = permalink
        self.date = date
    }

    /// 占位默认值（对齐 Android Motto.DEFAULT_ONLINE：首次进入不联网直接显示）。
    public static let defaultOnline = Motto(
        text: "我并不过分苛求一切完美，我只是不想半途而废。",
        author: "乔鲁诺·乔巴拿",
        source: "《JOJO 的奇妙冒险：黄金之风》",
        permalink: nil
    )

    /// 本地格言（对齐 Android Motto.local：author 空/「佚名」视为无作者；text 空回退默认）。
    public static func local(text: String, author: String) -> Motto {
        let trimmedAuthor = author.trimmingCharacters(in: .whitespaces)
        return Motto(
            text: text.isEmpty ? "笃学尚行" : text,
            author: (trimmedAuthor.isEmpty || trimmedAuthor == "佚名") ? nil : trimmedAuthor
        )
    }

    /// 署名行：`author 《source》`（两者皆缺返回 nil）。
    public var attribution: String? {
        switch (author?.isEmpty == false, source?.isEmpty == false) {
        case (true, true): return "\(author!) 《\(source!)》"
        case (true, false): return author
        case (false, true): return "《\(source!)》"
        case (false, false): return nil
        }
    }
}

/// 按天缓存（UserDefaults 独立 suite 单 JSON key，对齐 Android MottoCacheDataSource）。
public struct MottoCache {
    private let defaults: UserDefaults

    /// 生产入口（suite 不存在时落到 standard，与 SettingsStore 同策略）。
    public init() {
        self.defaults = UserDefaults(suiteName: "motto_cache") ?? .standard
    }

    /// 测试入口：注入隔离 suite。
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private static let key = "cached_motto"

    /// 当前缓存（无缓存返回 nil；date 默认填今天 → isFresh 为 false，触发首拉）。
    public func load() -> Motto? {
        guard let raw = defaults.string(forKey: Self.key),
              let data = raw.data(using: .utf8),
              let motto = try? JSONDecoder().decode(Motto.self, from: data) else { return nil }
        return motto
    }

    /// 当前缓存（无缓存时返回占位，date=今天；对齐 Android CachedMotto 默认值语义）。
    public func loadOrDefault() -> Motto {
        if var motto = load() {
            if motto.date.isEmpty { motto.date = Self.today() }
            return motto
        }
        return Motto(
            text: Motto.defaultOnline.text,
            author: Motto.defaultOnline.author,
            source: Motto.defaultOnline.source,
            permalink: Motto.defaultOnline.permalink,
            date: Self.today()
        )
    }

    public func save(_ motto: Motto) {
        guard let data = try? JSONEncoder().encode(motto),
              let raw = String(data: data, encoding: .utf8) else { return }
        defaults.set(raw, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    public static func isFresh(_ motto: Motto) -> Bool {
        motto.date == today()
    }

    static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}

/// hitokoto.cn 一言客户端（对齐 Android HitokotoClient.kt）。
public struct HitokotoClient: Sendable {
    public static let endpoint = "https://v1.hitokoto.cn/"
    public static let userAgent = "OpenJWC/1.0 (+https://github.com/OpenJWC)"

    /// 一言分类（对齐 Android HitokotoCategory：code a-l 缺 j）。
    public enum Category: String, CaseIterable, Sendable {
        case animation = "a", comic = "b", game = "c", literature = "d"
        case original = "e", web = "f", other = "g", video = "h"
        case poetry = "i", philosophy = "k", pun = "l"

        public var label: String {
            switch self {
            case .animation: return "动画"
            case .comic: return "漫画"
            case .game: return "游戏"
            case .literature: return "文学"
            case .original: return "原创"
            case .web: return "来自网络"
            case .other: return "其他"
            case .video: return "影视"
            case .poetry: return "诗词"
            case .philosophy: return "哲学"
            case .pun: return "抖机灵"
            }
        }
    }

    private let session: URLSession

    /// 超时：connect 10s（对齐 Android）；请求整体由调用方 Task 语义控制。
    public init(session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()) {
        self.session = session
    }

    /// 拉取一言并写成 Motto（date=今天）。
    /// category 空 = 不限；maxLength 收敛到 1...100（对齐 Android coerceIn）。
    public func fetch(category: String, minLength: Int = 0, maxLength: Int = 30) async throws -> Motto {
        var components = URLComponents(string: Self.endpoint)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "encode", value: "json"),
            URLQueryItem(name: "charset", value: "utf-8"),
            URLQueryItem(name: "min_length", value: String(max(0, minLength))),
            URLQueryItem(name: "max_length", value: String(min(max(1, maxLength), 100))),
        ]
        if !category.isEmpty {
            items.append(URLQueryItem(name: "c", value: category))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HitokotoError.badResponse
        }
        return try Self.parse(data)
    }

    /// 响应解析（对齐 Android HitokotoResponse：hitokoto 空白报错）。
    public static func parse(_ data: Data) throws -> Motto {
        struct Response: Decodable {
            let id: Int?
            let uuid: String?
            let hitokoto: String?
            let type: String?
            let from: String?
            let fromWho: String?

            enum CodingKeys: String, CodingKey {
                case id, uuid, hitokoto, type, from
                case fromWho = "from_who"
            }
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.hitokoto?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw HitokotoError.emptyHitokoto
        }
        return Motto(
            text: text,
            author: decoded.fromWho?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            source: decoded.from?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            permalink: decoded.uuid.map { "https://hitokoto.cn?id=\($0)" } ??
                decoded.id.map { "https://hitokoto.cn?id=\($0)" },
            date: MottoCache.today()
        )
    }
}

public enum HitokotoError: Error, LocalizedError {
    case badResponse
    case emptyHitokoto

    public var errorDescription: String? {
        switch self {
        case .badResponse: return "一言服务暂不可用"
        case .emptyHitokoto: return "一言返回内容为空"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
