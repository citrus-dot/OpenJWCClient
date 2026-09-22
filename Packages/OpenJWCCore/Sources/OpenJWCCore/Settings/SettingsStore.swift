import Foundation

/// LLM provider 配置（不含 API Key）。结构对齐 Android `LlmProviderConfig`，
/// JSON 字段名与 kotlinx 序列化一致（max_tokens 蛇形）。
public struct LlmProviderConfig: Codable, Equatable, Hashable, Sendable {
    public var providerId: String
    public var `protocol`: String
    public var baseUrl: String
    public var model: String
    public var temperature: Double
    public var maxTokens: Int

    public init(
        providerId: String = "openai",
        protocol: String = "OPENAI",
        baseUrl: String = "https://api.openai.com/v1",
        model: String = "gpt-4o-mini",
        temperature: Double = 0.7,
        maxTokens: Int = 2048
    ) {
        self.providerId = providerId
        self.`protocol` = `protocol`
        self.baseUrl = baseUrl
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    enum CodingKeys: String, CodingKey {
        case providerId
        case `protocol`
        case baseUrl
        case model
        case temperature
        case maxTokens = "max_tokens"
    }
}

/// 用户设置快照：字段与默认值逐项对齐 Android `UserSettings`。
public struct UserSettings: Codable, Equatable, Sendable {
    public var policyAgreed: Bool = false
    public var themeStyle: String = "Auto"          // Auto | Light | Dark
    public var themeColorStorage: String = ""       // "" = 默认（Dynamic）；自定义色格式 UI 层定义
    public var freshDays: Int = 21
    public var backgroundPath: String? = nil        // iOS 存容器相对路径（绝对路径随安装变化）
    public var backgroundAlpha: Double = 0.3
    public var proxyType: String = "none"           // none | http | socks
    public var proxyAddress: String = ""
    public var proxyPort: Int = 0
    public var languageCode: String? = nil
    public var currentTableId: Int64? = nil
    public var showTimeline: Bool = true
    public var showDate: Bool = true
    public var showPeriodTime: Bool = true
    public var showNonCurrentWeek: Bool = true
    public var newsNotificationEnabled: Bool = false
    public var newsCheckIntervalMinutes: Int = 60
    public var courseReminderEnabled: Bool = false
    public var permissionReminderDismissed: Bool = false
    public var autoStartEnabled: Bool = false
    public var dailyReportEnabled: Bool = false
    /// HH:mm，本地时区。
    public var dailyReportTime: String = "00:10"
    /// 抓取回溯天数（与显示用的 freshDays 解耦）。
    public var crawlDaysGap: Int = 200
    public var mottoText: String = "笃学尚行"
    public var mottoAuthor: String = ""
    public var mottoOnline: Bool = true
    public var hitokotoCategory: String = ""
    public var hitokotoMaxLength: Int = 30

    public init() {}
}

/// 供应商无关的对话消息（配置档案共用 LlmProviderConfig）。

/// LLM 配置档案（多套存档管理）：一份 = 一个供应商端点 + 模型 + 显示名。
/// API Key 不在其中——按 profile.id 隔离存于 LlmKeyStore。
public struct LlmProfile: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var config: LlmProviderConfig
    public var isActive: Bool

    public init(id: String = UUID().uuidString, name: String, config: LlmProviderConfig, isActive: Bool = false) {
        self.id = id
        self.name = name
        self.config = config
        self.isActive = isActive
    }

    /// 激活态单选约束：至多一个 isActive；无激活时首个为激活。
    public static func normalize(_ profiles: [LlmProfile]) -> [LlmProfile] {
        guard !profiles.isEmpty else { return profiles }
        var result = profiles
        let activeCount = result.filter(\.isActive).count
        if activeCount == 0 { result[0].isActive = true }
        if activeCount > 1 {
            var seen = false
            for i in result.indices {
                if result[i].isActive {
                    if seen { result[i].isActive = false } else { seen = true }
                }
            }
        }
        return result
    }
}

/// 用户设置存储：UserDefaults 双命名域对位 Android 两个 DataStore（llm_prefs / user_settings）。
/// 本阶段提供快照读写；值观察（AsyncStream 桥接 KVO）留到 UI 阶段实现。
/// UserDefaults 本身线程安全，跨 actor 持有安全（@unchecked）。
public struct SettingsStore: @unchecked Sendable {
    private let llmDefaults: UserDefaults
    private let settingsDefaults: UserDefaults

    /// 生产入口：独立 suite 对位独立 DataStore 文件。
    public init() {
        self.llmDefaults = UserDefaults(suiteName: "llm_prefs") ?? .standard
        self.settingsDefaults = UserDefaults(suiteName: "user_settings") ?? .standard
    }

    /// 测试入口：注入隔离的 UserDefaults（调用方负责清理 suite）。
    public init(llmDefaults: UserDefaults, settingsDefaults: UserDefaults) {
        self.llmDefaults = llmDefaults
        self.settingsDefaults = settingsDefaults
    }

    // MARK: - LLM 配置档案（多套存档；独立 key，旧 provider_config 保留兼容）

    private static let profilesKey = "provider_profiles"

    /// 全部配置档案（按激活优先、名称次序）。
    public func loadProfiles() -> [LlmProfile] {
        guard let raw = llmDefaults.string(forKey: Self.profilesKey),
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([LlmProfile].self, from: data) else {
            return []
        }
        return list
    }

    public func saveProfiles(_ profiles: [LlmProfile]) {
        // 激活态单选约束
        let normalized = LlmProfile.normalize(profiles)
        guard let data = try? JSONEncoder().encode(normalized),
              let raw = String(data: data, encoding: .utf8) else { return }
        llmDefaults.set(raw, forKey: Self.profilesKey)
    }

    /// 当前激活档案；无档案时从旧单配置迁移（provider_config → 首个激活档案，幂等）。
    public func loadActiveProfile() -> LlmProfile? {
        let existing = loadProfiles()
        if let active = existing.first(where: \.isActive) { return active }
        if let first = existing.first { return first }
        // 迁移：旧单配置 → 首个档案（不写回，下次 saveProfiles 落盘）
        return LlmProfile(name: defaultProfileName(for: loadLlmConfig()), config: loadLlmConfig(), isActive: true)
    }

    private func defaultProfileName(for config: LlmProviderConfig) -> String {
        LlmPresets.byId(config.providerId).name
    }

    // MARK: - LLM 配置（单键 JSON，整体存取；未来加字段零迁移）

    public func loadLlmConfig() -> LlmProviderConfig {
        guard let raw = llmDefaults.string(forKey: "provider_config"),
              let data = raw.data(using: .utf8) else {
            return LlmProviderConfig()
        }
        // 解析失败回退默认（对齐 Android runCatching 回退）。
        return (try? JSONDecoder().decode(LlmProviderConfig.self, from: data)) ?? LlmProviderConfig()
    }

    public func saveLlmConfig(_ config: LlmProviderConfig) {
        guard let data = try? JSONEncoder().encode(config),
              let raw = String(data: data, encoding: .utf8) else { return }
        llmDefaults.set(raw, forKey: "provider_config")
    }

    // MARK: - 用户设置（逐 key，key 名与 Android 一致 snake_case）

    public func loadUserSettings() -> UserSettings {
        var s = UserSettings()
        let d = settingsDefaults
        s.policyAgreed = d.object(forKey: "policy_agreed") as? Bool ?? s.policyAgreed
        s.themeStyle = d.string(forKey: "theme_style") ?? s.themeStyle
        s.themeColorStorage = d.string(forKey: "theme_color") ?? s.themeColorStorage
        s.freshDays = d.object(forKey: "fresh_days") as? Int ?? s.freshDays
        s.backgroundPath = d.string(forKey: "background_path").flatMap { $0.isEmpty ? nil : $0 }
        s.backgroundAlpha = d.object(forKey: "background_alpha") as? Double ?? s.backgroundAlpha
        s.proxyType = d.string(forKey: "proxy_type") ?? s.proxyType
        s.proxyAddress = d.string(forKey: "proxy_address") ?? s.proxyAddress
        s.proxyPort = d.object(forKey: "proxy_port") as? Int ?? s.proxyPort
        s.languageCode = d.string(forKey: "language_code").flatMap { $0.isEmpty ? nil : $0 }
        let tableId = d.object(forKey: "current_table_id") as? Int64
        s.currentTableId = (tableId == 0) ? nil : tableId
        s.showTimeline = d.object(forKey: "show_timeline") as? Bool ?? s.showTimeline
        s.showDate = d.object(forKey: "show_date") as? Bool ?? s.showDate
        s.showPeriodTime = d.object(forKey: "show_period_time") as? Bool ?? s.showPeriodTime
        s.showNonCurrentWeek = d.object(forKey: "show_non_current_week") as? Bool ?? s.showNonCurrentWeek
        s.newsNotificationEnabled = d.object(forKey: "news_notification_enabled") as? Bool ?? s.newsNotificationEnabled
        s.newsCheckIntervalMinutes = d.object(forKey: "news_check_interval_minutes") as? Int ?? s.newsCheckIntervalMinutes
        s.courseReminderEnabled = d.object(forKey: "course_reminder_enabled") as? Bool ?? s.courseReminderEnabled
        s.permissionReminderDismissed = d.object(forKey: "permission_reminder_dismissed") as? Bool ?? s.permissionReminderDismissed
        s.autoStartEnabled = d.object(forKey: "auto_start_enabled") as? Bool ?? s.autoStartEnabled
        s.dailyReportEnabled = d.object(forKey: "daily_report_enabled") as? Bool ?? s.dailyReportEnabled
        s.dailyReportTime = d.string(forKey: "daily_report_time") ?? s.dailyReportTime
        s.crawlDaysGap = d.object(forKey: "crawl_days_gap") as? Int ?? s.crawlDaysGap
        s.mottoText = d.string(forKey: "motto_text") ?? s.mottoText
        s.mottoAuthor = d.string(forKey: "motto_author") ?? s.mottoAuthor
        s.mottoOnline = d.object(forKey: "motto_online") as? Bool ?? s.mottoOnline
        s.hitokotoCategory = d.string(forKey: "hitokoto_category") ?? s.hitokotoCategory
        s.hitokotoMaxLength = d.object(forKey: "hitokoto_max_length") as? Int ?? s.hitokotoMaxLength
        return s
    }

    public func saveUserSettings(_ settings: UserSettings) {
        let d = settingsDefaults
        d.set(settings.policyAgreed, forKey: "policy_agreed")
        d.set(settings.themeStyle, forKey: "theme_style")
        d.set(settings.themeColorStorage, forKey: "theme_color")
        d.set(settings.freshDays, forKey: "fresh_days")
        d.set(settings.backgroundPath ?? "", forKey: "background_path")
        d.set(settings.backgroundAlpha, forKey: "background_alpha")
        d.set(settings.proxyType, forKey: "proxy_type")
        d.set(settings.proxyAddress, forKey: "proxy_address")
        d.set(settings.proxyPort, forKey: "proxy_port")
        d.set(settings.languageCode ?? "", forKey: "language_code")
        d.set(settings.currentTableId ?? 0, forKey: "current_table_id")
        d.set(settings.showTimeline, forKey: "show_timeline")
        d.set(settings.showDate, forKey: "show_date")
        d.set(settings.showPeriodTime, forKey: "show_period_time")
        d.set(settings.showNonCurrentWeek, forKey: "show_non_current_week")
        d.set(settings.newsNotificationEnabled, forKey: "news_notification_enabled")
        d.set(settings.newsCheckIntervalMinutes, forKey: "news_check_interval_minutes")
        d.set(settings.courseReminderEnabled, forKey: "course_reminder_enabled")
        d.set(settings.permissionReminderDismissed, forKey: "permission_reminder_dismissed")
        d.set(settings.autoStartEnabled, forKey: "auto_start_enabled")
        d.set(settings.dailyReportEnabled, forKey: "daily_report_enabled")
        d.set(settings.dailyReportTime, forKey: "daily_report_time")
        d.set(settings.crawlDaysGap, forKey: "crawl_days_gap")
        d.set(settings.mottoText, forKey: "motto_text")
        d.set(settings.mottoAuthor, forKey: "motto_author")
        d.set(settings.mottoOnline, forKey: "motto_online")
        d.set(settings.hitokotoCategory, forKey: "hitokoto_category")
        d.set(settings.hitokotoMaxLength, forKey: "hitokoto_max_length")
    }

    /// 已删除的侧载数据源 id 集合（对齐 Android stringSetPreferencesKey）。
    public func loadDeletedSourceIds() -> Set<String> {
        guard let raw = settingsDefaults.string(forKey: "deleted_source_ids"),
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list)
    }

    public func saveDeletedSourceIds(_ ids: Set<String>) {
        guard let data = try? JSONEncoder().encode(ids.sorted()),
              let raw = String(data: data, encoding: .utf8) else { return }
        settingsDefaults.set(raw, forKey: "deleted_source_ids")
    }
}
