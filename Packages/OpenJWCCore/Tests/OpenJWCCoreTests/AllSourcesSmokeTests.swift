import Foundation
import Testing
@testable import OpenJWCCore

/// 组 9 验收：39 个内置源全量冒烟（依赖外网，单跑 `--filter AllSourcesSmoke`）。
/// 逐脚本 manifest 解析 + 真实列表抓取，逐源记录失败/告警（roadmap 阶段 4 验收扩展）。
/// 逐源详情见运行输出 [smoke] / [smoke-warn] 行。
@Suite("AllSourcesSmoke", .serialized)
struct AllSourcesSmokeTests {

    @Test("39 源全量冒烟：逐源抓取无致命失败")
    func smokeAllSources() async throws {
        let files = try FileManager.default
            .contentsOfDirectory(atPath: ScriptAcceptanceTests.scriptRoot.path)
            .filter { $0.lowercased().hasSuffix(".js") }
            .sorted()
        #expect(files.count == 39, "内置脚本应为 39 个，实际 \(files.count)")

        var failures: [String] = []
        var warningLines: [String] = []
        var fetchedTotal = 0

        for file in files {
            do {
                let outcome = try await ScriptAcceptanceTests().runReal(file)
                fetchedTotal += outcome.notices.count
                print("[smoke] \(file): fetched=\(outcome.notices.count) scanned=\(outcome.scanned) " +
                      "skipped=\(outcome.skipped) failed=\(outcome.failed) noContent=\(outcome.noContent)")
                if !outcome.warnings.isEmpty {
                    warningLines.append("\(file): \(outcome.warnings.joined(separator: " | "))")
                }
                if outcome.notices.isEmpty {
                    failures.append("\(file): 抓取 0 条（列表为空或选择器失效）")
                }
            } catch {
                failures.append("\(file): \(error)")
            }
        }

        print("[smoke] ===== 汇总：\(files.count) 源，累计抓取 \(fetchedTotal) 条，警告源 \(warningLines.count) 个 =====")
        warningLines.forEach { print("[smoke-warn] \($0)") }
        #expect(failures.isEmpty, "失败源清单：\n\(failures.joined(separator: "\n"))")
    }
}
