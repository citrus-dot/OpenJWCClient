import Foundation
import GRDB
import OpenJWCCore

/// Agent 组装根（对齐 Android AgentLoopFactory）：每次发送按当前配置新组装，
/// 用户改 LLM 配置立即生效，无需重启。
/// Keychain API 本身线程安全，@unchecked Sendable 成立。
struct AgentRuntime: @unchecked Sendable {
    private let settings: SettingsStore
    private let keyStore = LlmKeyStore()
    private let db: any DatabaseWriter

    init(settings: SettingsStore, db: any DatabaseWriter) {
        self.settings = settings
        self.db = db
    }

    /// 按当前配置组装 AgentLoop；课表/日报工具源待阶段 6 接入后补。
    func makeLoop() -> AgentLoop {
        let config = settings.loadLlmConfig()
        let apiKey = ((try? keyStore.load(for: config.providerId)) ?? "") ?? ""
        let client = OpenAiCompatibleClient(config: config, apiKey: apiKey)
        let corpus = GrdbNoticeCorpus(db: db)
        return AgentLoop(
            client: client,
            tools: AgentTools(repository: corpus),
            repository: corpus
        )
    }
}
