import Testing
import Foundation
import GRDB
@testable import OpenJWCCore

/// SourceRegistry 播种测试（tasks 组 3）：空库播种 / 幂等 / 删除装回。
/// 用临时文件 DB + Fixtures/SeedSources 假脚本，不依赖 app 资产。
@Suite("SourceRegistry 播种")
struct SourceRegistryTests {

    private func makeTempDB() throws -> DatabaseProvider {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openjwc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DatabaseProvider(databasePath: dir.appendingPathComponent("test.sqlite").path)
    }

    private func makeSettings() throws -> (SettingsStore, String) {
        let name = "openjwc-test-\(UUID().uuidString)"
        let llm = UserDefaults(suiteName: name + "-llm")!
        let settings = UserDefaults(suiteName: name + "-settings")!
        return (SettingsStore(llmDefaults: llm, settingsDefaults: settings), name)
    }

    private func seedDirectory() throws -> URL {
        let root = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/SeedSources")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("fake-jwc.js").path))
        return root
    }

    @Test("空库首次播种：全部内置源入库、仅 seu-jwc 默认订阅、缺 @id 跳过")
    func firstRunSeeding() async throws {
        let db = try makeTempDB()
        let (settings, suite) = try makeSettings()
        defer { UserDefaults().removePersistentDomain(forName: suite + "-llm")
                UserDefaults().removePersistentDomain(forName: suite + "-settings") }

        let registry = SourceRegistry(db: db.dbWriter, settings: settings)
        let result = try await registry.syncBuiltIns(scriptDirectory: seedDirectory())

        #expect(result.installed == 2)
        #expect(result.skippedFiles == ["no-id.js"])

        let dao = SourceDao(db: db.dbWriter)
        let all = try await dao.getAll()
        #expect(all.count == 2)

        let jwc = try #require(try await dao.getById(id: "seu-jwc"))
        #expect(jwc.subscribed)
        #expect(jwc.name == "教务处（测试副本）")
        #expect(jwc.origin == "builtin")
        #expect(jwc.domains.value == ["example.com"])
        #expect(jwc.labels.value == ["通知", "测试"])
        #expect(jwc.scheduleMinutes == 60)

        let other = try #require(try await dao.getById(id: "fake-other"))
        #expect(!other.subscribed)
    }

    @Test("二次启动幂等：不覆盖用户订阅态，不重复插入")
    func idempotentReseed() async throws {
        let db = try makeTempDB()
        let (settings, suite) = try makeSettings()
        defer { UserDefaults().removePersistentDomain(forName: suite + "-llm")
                UserDefaults().removePersistentDomain(forName: suite + "-settings") }

        let registry = SourceRegistry(db: db.dbWriter, settings: settings)
        let dao = SourceDao(db: db.dbWriter)
        _ = try await registry.syncBuiltIns(scriptDirectory: seedDirectory())

        // 用户手动订阅了非默认源
        try await dao.setSubscribed(id: "fake-other", subscribed: true)
        _ = try await registry.syncBuiltIns(scriptDirectory: seedDirectory())

        let all = try await dao.getAll()
        #expect(all.count == 2)
        #expect(try await dao.getById(id: "fake-other")!.subscribed)
        #expect(try await dao.getById(id: "seu-jwc")!.subscribed)
    }

    @Test("已删除的内置源重新装回：默认不订阅并清除删除记录")
    func deletedSourceRestored() async throws {
        let db = try makeTempDB()
        let (settings, suite) = try makeSettings()
        defer { UserDefaults().removePersistentDomain(forName: suite + "-llm")
                UserDefaults().removePersistentDomain(forName: suite + "-settings") }

        try settings.saveDeletedSourceIds(["fake-other"])

        let registry = SourceRegistry(db: db.dbWriter, settings: settings)
        let dao = SourceDao(db: db.dbWriter)
        _ = try await registry.syncBuiltIns(scriptDirectory: seedDirectory())

        let other = try #require(try await dao.getById(id: "fake-other"))
        #expect(!other.subscribed)
        #expect(!settings.loadDeletedSourceIds().contains("fake-other"))
        #expect(try await dao.getById(id: "seu-jwc")!.subscribed)
    }
}
