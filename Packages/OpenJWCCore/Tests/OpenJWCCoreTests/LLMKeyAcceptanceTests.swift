import Foundation
import Testing
@testable import OpenJWCCore

/// 阶段 3 遗留验收：真实 Key 流式多轮工具调用（roadmap §8 待办项）。
/// Key 从 `~/.openjwc-llm-key` 读取（600 权限，不入仓库）；文件不存在时本测试自动跳过。
/// Base URL / 模型名为百炼 OpenAI 兼容端点（公网 https，非敏感）。
@Suite("LLMKeyAcceptance", .serialized)
struct LLMKeyAcceptanceTests {
    static let keyPath = NSString(string: "~/.openjwc-llm-key").expandingTildeInPath
    static let baseUrl = "https://ws-29wcpji8gsrfgjf9.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
    static let model = "deepseek-v4.1-flash"

    @Test("真实 Key：SSE 流式 + 多轮工具调用 + 带引用终答")
    func realKeyStreamingToolCall() async throws {
        guard FileManager.default.fileExists(atPath: Self.keyPath),
              let apiKey = try? String(contentsOfFile: Self.keyPath, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            print("[skip] 未找到 ~/.openjwc-llm-key，跳过真实 Key 联测")
            return
        }

        // 1. 灌语料：JSC 宿主真实抓取教务处（顺带验证脚本层 → 数据层集成）
        let provider = try DatabaseProvider(inMemory: true)
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../app/src/main/assets/sources/seu-jwc.js")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let host = JavaScriptHost()
        let sandbox = ScriptSandbox(
            allowedDomains: Set(ScriptManifestParser.parse(script)?.domains ?? []),
            timeoutMs: 240_000, maxHttpCalls: 600
        )
        let crawl = try await host.run(
            script: script, sandbox: sandbox,
            params: ScriptRunParams(crawlDaysGap: 200)
        )
        let corpus = GrdbNoticeCorpus(db: provider.dbWriter)
        try await NoticeDao(db: provider.dbWriter).upsertAll(crawl.notices.map { notice in
            NoticeRecord(
                id: notice.id, sourceId: "seu-jwc", label: notice.label, title: notice.title,
                publishedAt: Self.dayMillis(notice.date), publishedDay: notice.date,
                detailUrl: notice.detailUrl, isPage: notice.isPage,
                content: notice.contentText, contentVersion: 1,
                attachments: notice.attachments.map { JSONStringList($0) },
                fetchedAt: Int64(Date().timeIntervalSince1970 * 1000),
                notified: false, favorite: false
            )
        })
        let corpusCount = try await corpus.corpusCatalog().total
        print("[联测] 语料灌入 \(corpusCount) 条（脚本抓取 \(crawl.notices.count) 条）")
        try #require(corpusCount > 0, "语料灌入失败，无法联测检索工具")

        // 2. 真实 AgentLoop（百炼 OpenAI 兼容端点）
        let config = LlmProviderConfig(
            providerId: "bailian", protocol: "OPENAI",
            baseUrl: Self.baseUrl, model: Self.model
        )
        let client = OpenAiCompatibleClient(config: config, apiKey: apiKey)
        let tools = AgentTools(repository: corpus)
        let loop = AgentLoop(client: client, tools: tools, repository: corpus)

        var events: [AgentEvent] = []
        var streamedText = ""
        var bufferedText = ""
        for await event in loop.run(AgentRequest(
            query: "最近有什么考试类的通知？请给出通知标题、日期和链接。"
        )) {
            switch event {
            case .runStarted(let runId):
                print("[联测] ▶ run=\(runId)")
            case .toolStarted(_, let name, _, let targetId):
                print("[联测] 🔧 工具开始：\(name) target=\(targetId ?? "-")")
            case .toolCompleted(_, let name, let status, let durationMs, let code):
                print("[联测] 🔧 工具结束：\(name) status=\(status) \(durationMs)ms \(code.map { "code=\($0)" } ?? "")")
            case .answerDelta(let text, let delivery):
                if delivery == "streaming-final" {
                    streamedText += text
                    print("[流式] \(text)", terminator: "")
                } else {
                    bufferedText += text
                }
            case .runCompleted:
                print("\n[联测] ✔ 运行完成")
            case .runFailed(_, let code, let summary):
                print("\n[联测] ✘ 运行失败 code=\(code) \(summary)")
                Issue.record("Agent 运行失败：\(code) \(summary)")
                return
            }
            events.append(event)
        }

        // 3. 核对四点
        var runStartedCount = 0
        var toolStartedCount = 0
        var toolCompletedCount = 0
        var streamingDeltaCount = 0
        var runCompletedCount = 0
        for event in events {
            switch event {
            case .runStarted: runStartedCount += 1
            case .toolStarted: toolStartedCount += 1
            case .toolCompleted(_, _, let status, _, _) where status == "completed": toolCompletedCount += 1
            case .answerDelta(_, let delivery) where delivery == "streaming-final": streamingDeltaCount += 1
            case .runCompleted: runCompletedCount += 1
            default: break
            }
        }
        #expect(runStartedCount == 1)
        #expect(toolStartedCount >= 1)                 // ② 有工具调用
        #expect(toolCompletedCount >= 1)
        #expect(streamingDeltaCount > 0)               // ① SSE 流式可见
        #expect(!streamedText.isEmpty)
        #expect(streamedText.count > 20)               // ③ 终答有实质内容
        #expect(runCompletedCount == 1)                // ④ 事件流闭合
        guard case .runCompleted = events.last else { Issue.record("末事件应为 RunCompleted"); return }
        print("[联测] 流式正文（前 400 字）：\(String(streamedText.prefix(400)))")
        print("[联测] 工具轨迹事件数：\(events.count)，流式 delta 数：\(streamingDeltaCount)")
    }

    private static func dayMillis(_ day: String) -> Int64 {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = formatter.date(from: day) ?? Date()
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
