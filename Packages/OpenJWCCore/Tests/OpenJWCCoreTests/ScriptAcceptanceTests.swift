import Foundation
import Testing
@testable import OpenJWCCore

/// 阶段 2d 验收：Android 仓库内置脚本在 JSC 宿主上真实跑通（依赖外网，单跑 `--filter ScriptAcceptance`）。
/// 脚本真源：`app/src/main/assets/sources/*.js`（与 QuickJS 同一份 ES2020 资产，JSC 零修改复用）。
@Suite("ScriptAcceptance", .serialized)
struct ScriptAcceptanceTests {
    static let scriptRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/OpenJWCCoreTests
        .appendingPathComponent("../../../../app/src/main/assets/sources")

    func loadScript(_ name: String) throws -> String {
        let url = Self.scriptRoot.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func runReal(_ name: String, crawlDaysGap: Int = 200) async throws -> ScriptOutcome {
        let script = try loadScript(name)
        let manifest = try #require(ScriptManifestParser.parse(script))
        let host = JavaScriptHost()
        let sandbox = ScriptSandbox(
            allowedDomains: Set(manifest.domains),
            timeoutMs: 240_000,
            maxHttpCalls: 600
        )
        return try await host.run(
            script: script,
            sandbox: sandbox,
            params: ScriptRunParams(crawlDaysGap: crawlDaysGap),
            onLog: { print("[log] \($0)") }
        )
    }

    @Test("seu-jwc：教务处 7 栏目真实抓取")
    func seuJwc() async throws {
        let outcome = try await runReal("seu-jwc.js")
        #expect(!outcome.notices.isEmpty)
        #expect(outcome.failed == 0)
        for notice in outcome.notices.prefix(5) {
            #expect(!notice.id.isEmpty)
            #expect(notice.id.count == 64)
            #expect(!notice.title.isEmpty)
            #expect(notice.date.contains("-"))
            #expect(notice.detailUrl.hasPrefix("http"))
            #expect(notice.date >= Self.cutoff(200))
        }
    }

    @Test("seu-cs：计算机学院真实抓取")
    func seuCs() async throws {
        let outcome = try await runReal("seu-cs.js")
        #expect(!outcome.notices.isEmpty)
        #expect(outcome.failed == 0)
    }

    @Test("seu-xsxy：人文学院真实抓取")
    func seuXsxy() async throws {
        let outcome = try await runReal("seu-xsxy.js")
        print("[verbose] notices=\(outcome.notices.count) scanned=\(outcome.scanned) skipped=\(outcome.skipped) failed=\(outcome.failed) noContent=\(outcome.noContent) restricted=\(outcome.restricted) warnings=\(outcome.warnings)")
        #expect(!outcome.notices.isEmpty)
        #expect(outcome.failed == 0)
    }

    static func cutoff(_ days: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Calendar.current.date(byAdding: .day, value: -days, to: Date())!)
    }
}
