import Foundation
import Testing
@testable import OpenJWCCore

/// Requirement: LLM Key Keychain 存取 / 用户设置存取
@Suite("Keychain & Settings")
struct KeychainAndSettingsTests {
    @Test("Keychain 多 provider 隔离 + 回环 + 删除")
    func keychainRoundTrip() async throws {
        let store = LlmKeyStore()
        let providers = ["test-provider-\(UUID().uuidString)", "test-provider-2-\(UUID().uuidString)"]
        defer { providers.forEach { store.delete(for: $0) } }

        try store.save("sk-aaa", for: providers[0])
        try store.save("sk-bbb", for: providers[1])
        #expect(try store.load(for: providers[0]) == "sk-aaa")
        #expect(try store.load(for: providers[1]) == "sk-bbb")

        // 覆盖写
        try store.save("sk-aaa2", for: providers[0])
        #expect(try store.load(for: providers[0]) == "sk-aaa2")

        // 空串视为未设置
        try store.save("", for: providers[0])
        #expect(try store.load(for: providers[0]) == nil)

        store.delete(for: providers[1])
        #expect(try store.load(for: providers[1]) == nil)
    }

    @Test("设置默认值与 Android 端一致")
    func defaultsAligned() async throws {
        let suite = "test-settings-\(UUID().uuidString)"
        let store = SettingsStore(
            llmDefaults: UserDefaults(suiteName: suite)!,
            settingsDefaults: UserDefaults(suiteName: suite)!
        )
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let s = store.loadUserSettings()
        #expect(s.freshDays == 21)
        #expect(s.newsCheckIntervalMinutes == 60)
        #expect(s.dailyReportTime == "00:10")
        #expect(s.crawlDaysGap == 200)
        #expect(s.mottoText == "笃学尚行")
        #expect(s.hitokotoMaxLength == 30)
        #expect(s.backgroundAlpha == 0.3)
        #expect(s.showTimeline)

        let llm = store.loadLlmConfig()
        #expect(llm == LlmProviderConfig())
        #expect(llm.providerId == "openai")
        #expect(llm.maxTokens == 2048)
    }

    @Test("设置回环 + LLM JSON 单键 + deletedSourceIds")
    func roundTrip() async throws {
        let suite = "test-settings-\(UUID().uuidString)"
        let store = SettingsStore(
            llmDefaults: UserDefaults(suiteName: suite)!,
            settingsDefaults: UserDefaults(suiteName: suite)!
        )
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        var s = UserSettings()
        s.freshDays = 7
        s.currentTableId = 42
        s.proxyType = "http"
        s.proxyAddress = "127.0.0.1"
        s.proxyPort = 7880
        s.dailyReportEnabled = true
        store.saveUserSettings(s)
        let loaded = store.loadUserSettings()
        #expect(loaded.freshDays == 7)
        #expect(loaded.currentTableId == 42)
        #expect(loaded.proxyType == "http")

        var llm = LlmProviderConfig()
        llm.providerId = "deepseek"
        llm.model = "deepseek-chat"
        llm.maxTokens = 4096
        store.saveLlmConfig(llm)
        #expect(store.loadLlmConfig() == llm)

        store.saveDeletedSourceIds(["a", "b"])
        #expect(store.loadDeletedSourceIds() == ["a", "b"])
    }
}
