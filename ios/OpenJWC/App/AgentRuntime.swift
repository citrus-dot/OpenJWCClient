import Foundation
import GRDB
import OpenJWCCore

/// Agent 组装根（对齐 Android AgentLoopFactory）：每次发送按当前**激活档案**新组装，
/// 用户改配置立即生效，无需重启。
/// Keychain API 本身线程安全（含 UserDefaults 回退），@unchecked Sendable 成立。
struct AgentRuntime: @unchecked Sendable {
    private let settings: SettingsStore
    private let keyStore = LlmKeyStore()
    private let db: any DatabaseWriter

    init(settings: SettingsStore, db: any DatabaseWriter) {
        self.settings = settings
        self.db = db
    }

    /// 按激活档案组装 AgentLoop；无档案（未配置）→ AgentLoop 收到缺 Key 客户端，
    /// 首个事件即 runFailed(agent_configuration_error)（UI 提示去设置）。
    func makeLoop() -> AgentLoop {
        let profile = settings.loadActiveProfile()
        let apiKey: String
        if let profile {
            apiKey = (try? keyStore.load(for: Self.keyAccount(profile.id))) ?? nil ?? ""
        } else {
            apiKey = ""
        }
        let client = OpenAiCompatibleClient(
            config: profile?.config ?? LlmProviderConfig(),
            apiKey: apiKey
        )
        let corpus = GrdbNoticeCorpus(db: db)
        return AgentLoop(
            client: client,
            // D-5：注入课表源 → get_timetable/list_timetables/get_courses_on/find_course 自动暴露
            tools: AgentTools(repository: corpus, timetable: GrdbTimetableSource(db: db)),
            repository: corpus
        )
    }

    /// Key 隔离键：按档案 id（多档案可同供应商不同 Key）。
    static func keyAccount(_ profileId: String) -> String {
        "profile-\(profileId)"
    }
}
