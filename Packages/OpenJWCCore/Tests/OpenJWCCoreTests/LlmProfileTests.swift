import Foundation
import Testing
@testable import OpenJWCCore

/// LLM 配置档案管理测试（用户需求：多套存档 + 添加/修改/删除 + 激活单选）。
@Suite("LLM 配置档案")
struct LlmProfileTests {

    private func makeStore() -> (SettingsStore, String) {
        let suite = "llm-profile-test-\(UUID().uuidString)"
        let store = SettingsStore(
            llmDefaults: UserDefaults(suiteName: suite)!,
            settingsDefaults: UserDefaults(suiteName: suite)!
        )
        return (store, suite)
    }

    @Test("profiles 往返 + 激活单选 normalize")
    func roundTripAndNormalize() throws {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        #expect(store.loadProfiles().isEmpty)

        var a = LlmProfile(name: "主力", config: LlmProviderConfig(providerId: "deepseek", baseUrl: "https://api.deepseek.com/v1", model: "deepseek-chat"), isActive: true)
        let b = LlmProfile(name: "备用", config: LlmProviderConfig(providerId: "openai", baseUrl: "https://api.openai.com/v1", model: "gpt-4o-mini"))
        store.saveProfiles([a, b])
        let loaded = store.loadProfiles()
        #expect(loaded.count == 2)
        #expect(loaded[0].isActive && !loaded[1].isActive)

        // 双激活 → 归一为单选
        a.isActive = true
        var c = b
        c.isActive = true
        c.id = "another"
        let normalized = LlmProfile.normalize([a, c])
        #expect(normalized.filter(\.isActive).count == 1)

        // 零激活 → 首个激活
        var d = a; d.isActive = false
        var e = b; e.isActive = false
        let fallback = LlmProfile.normalize([d, e])
        #expect(fallback[0].isActive && !fallback[1].isActive)
    }

    @Test("无档案时从旧单配置迁移（幂等语义，不覆盖已存档案）")
    func legacyMigration() throws {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        // 旧单配置
        var legacy = LlmProviderConfig()
        legacy.providerId = "deepseek"
        legacy.baseUrl = "https://api.deepseek.com/v1"
        legacy.model = "deepseek-chat"
        store.saveLlmConfig(legacy)

        // 无 profiles → activeProfile 从旧配置迁出
        let migrated = store.loadActiveProfile()
        #expect(migrated?.config == legacy)
        #expect(migrated?.isActive == true)
        #expect(migrated?.name == "DeepSeek")

        // 已有档案 → 不受旧配置影响
        let custom = LlmProfile(name: "已有", config: legacy, isActive: true)
        store.saveProfiles([custom])
        #expect(store.loadActiveProfile()?.id == custom.id)
    }

    @Test("KeyStore 回退：Keychain 不可用/未命中时回退存储仍可往返")
    func keyStoreFallback() throws {
        let store = LlmKeyStore()
        let account = "profile-test-\(UUID().uuidString)"
        defer { store.delete(for: account) }

        // 正常路径（macOS 测试环境 Keychain 可用；模拟器免签名自动走回退）
        try store.save("sk-profile-key", for: account)
        #expect(try store.load(for: account) == "sk-profile-key")

        // 覆盖 + 删除
        try store.save("sk-2", for: account)
        #expect(try store.load(for: account) == "sk-2")
        store.delete(for: account)
        #expect(try store.load(for: account) == nil)
    }
}
