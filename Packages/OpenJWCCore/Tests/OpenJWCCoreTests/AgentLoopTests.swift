import Foundation
import Testing
@testable import OpenJWCCore

/// 逐次返回预置增量的假客户端（对齐 Android FakeLlmClient）。
final class FakeLlmClient: LlmClient, @unchecked Sendable {
    let config = LlmProviderConfig()
    private let rounds: [[LlmDelta]]
    private(set) var calls = 0
    private(set) var lastTools: [LlmToolSpec] = []
    private let lock = NSLock()

    init(rounds: [[LlmDelta]]) {
        self.rounds = rounds
    }

    func streamChat(messages: [LlmMessage], tools: [LlmToolSpec]) -> AsyncThrowingStream<LlmDelta, Error> {
        lock.lock()
        let index = min(calls, rounds.count - 1)
        calls += 1
        lastTools = tools
        let deltas = rounds[index]
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for delta in deltas {
                continuation.yield(delta)
            }
            continuation.finish()
        }
    }
}

/// 内存语料：一条资讯（对齐 Android FakeCorpus）。
final class FakeCorpus: NoticeCorpus, @unchecked Sendable {
    let notice = NoticeRecord(
        id: "notice-1", sourceId: "seu-jwc", label: "教务信息",
        title: "关于期末考试安排的通知", publishedAt: 1_700_000_000_000,
        publishedDay: "2026-09-01", detailUrl: "https://jwc.seu.edu.cn/1",
        isPage: true, content: "考试时间：2026-09-20。", contentVersion: 1,
        attachments: nil, fetchedAt: 1_700_000_000_000, notified: false, favorite: false
    )

    func searchNotices(
        query: String, label: String, sourceId: String?, fromDay: String, toDay: String,
        favoriteOnly: Bool, relevance: Bool, limit: Int, offset: Int
    ) async throws -> [NoticeRecord] { [notice] }

    func countNotices(
        query: String, label: String, sourceId: String?, fromDay: String, toDay: String,
        favoriteOnly: Bool
    ) async throws -> Int { 1 }

    func findNotice(id: String) async throws -> NoticeRecord? {
        notice.id == id ? notice : nil
    }

    func corpusLabels() async throws -> [CorpusLabelCount] { [CorpusLabelCount(label: "教务信息", count: 1)] }

    func subscribedSources() async throws -> [NoticeSourceRecord] {
        [NoticeSourceRecord(
            id: "seu-jwc", name: "东南大学教务处", version: "1.0.1", origin: "builtin",
            scriptFile: nil, domains: JSONStringList([]), labels: JSONStringList(["教务信息"]),
            scheduleMinutes: 360, subscribed: true, lastRunAt: nil, lastCount: 0, lastError: nil
        )]
    }

    func corpusCatalog() async throws -> CorpusCatalog {
        CorpusCatalog(total: 1, firstDay: "2026-09-01", lastDay: "2026-09-01")
    }
}

private func toolCallRound(id: String, name: String, arguments: String) -> [LlmDelta] {
    [
        .toolCallDelta(index: 0, id: id, name: name, argumentsChunk: arguments),
        .finished("tool_calls"),
    ]
}

private func answerRound(_ text: String) -> [LlmDelta] {
    [.text(text), .finished("stop")]
}

/// 复刻 Android AgentLoopTest 的 4 个用例。
@Suite("AgentLoop")
struct AgentLoopTests {
    private func makeLoop(_ client: FakeLlmClient) -> AgentLoop {
        let corpus = FakeCorpus()
        return AgentLoop(
            client: client,
            tools: AgentTools(repository: corpus),
            repository: corpus
        )
    }

    private func collect(_ loop: AgentLoop, _ request: AgentRequest) async throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in loop.run(request) {
            events.append(event)
        }
        return events
    }

    @Test("工具轮之后用禁用工具的流式轮产出最终答案")
    func toolRoundThenFinalAnswer() async throws {
        let client = FakeLlmClient(rounds: [
            toolCallRound(id: "call_1", name: AgentTools.toolSearch, arguments: #"{"query":"考试"}"#),
            answerRound("期末考试安排在 2026-09-20。"),
        ])
        let events = try await collect(makeLoop(client), AgentRequest(query: "最近有什么考试通知？"))

        guard case .runStarted = events.first else { Issue.record("首事件应为 RunStarted"); return }
        #expect(events.filter { if case .toolStarted = $0 { true } else { false } }.count == 1)
        let completions = events.compactMap { event -> String? in
            if case .toolCompleted(_, _, let status, _, _) = event { return status }
            return nil
        }
        #expect(completions == [AgentEvent.statusCompleted])
        let deltas = events.compactMap { event -> (String, String)? in
            if case .answerDelta(let text, let delivery) = event { return (text, delivery) }
            return nil
        }
        #expect(deltas.count == 1)
        #expect(deltas[0].1 == AgentEvent.deliveryStreaming)
        #expect(deltas[0].0.contains("2026-09-20"))
        guard case .runCompleted = events.last else { Issue.record("末事件应为 RunCompleted"); return }
        // 工具轮 → 空工具轮 → 禁用工具的流式收束轮 = 3 次
        #expect(client.calls == 3)
        #expect(client.lastTools.isEmpty)
    }

    @Test("未使用工具时也走一次禁用工具的流式收束")
    func noToolRoundStillFinalizes() async throws {
        let client = FakeLlmClient(rounds: [answerRound("你好，我是教务资讯助手。")])
        let events = try await collect(makeLoop(client), AgentRequest(query: "你好"))

        let deltas = events.compactMap { event -> String? in
            if case .answerDelta(_, let delivery) = event { return delivery }
            return nil
        }
        #expect(deltas == [AgentEvent.deliveryStreaming])
        guard case .runCompleted = events.last else { Issue.record("末事件应为 RunCompleted"); return }
        // 工具轮 + 收束轮
        #expect(client.calls == 2)
        #expect(client.lastTools.isEmpty)
    }

    @Test("工具失败只作为失败观察，运行仍可成功")
    func toolFailureIsJustAnObservation() async throws {
        let client = FakeLlmClient(rounds: [
            toolCallRound(id: "call_1", name: AgentTools.toolRead, arguments: #"{"id":"missing"}"#),
            answerRound("没有找到该资讯。"),
        ])
        let events = try await collect(makeLoop(client), AgentRequest(query: "读一下 missing"))

        let failed = events.compactMap { event -> (String, String?)? in
            if case .toolCompleted(_, _, let status, _, let code) = event { return (status, code) }
            return nil
        }
        #expect(failed.count == 1)
        #expect(failed[0].0 == AgentEvent.statusFailed)
        #expect(failed[0].1 == "tool_not_found")
        guard case .runCompleted = events.last else { Issue.record("末事件应为 RunCompleted"); return }
        #expect(client.calls == 3)
    }

    @Test("每轮工具数超过上限时收束并补齐未执行观察")
    func perRoundToolLimit() async throws {
        var deltas: [LlmDelta] = (0...5).map {
            LlmDelta.toolCallDelta(index: $0, id: "call_\($0)", name: AgentTools.toolLabels, argumentsChunk: "{}")
        }
        deltas.append(.finished("tool_calls"))
        let client = FakeLlmClient(rounds: [deltas, answerRound("已停止检索。")])
        let events = try await collect(makeLoop(client), AgentRequest(query: "列出栏目"))

        #expect(events.filter { if case .toolStarted = $0 { true } else { false } }.isEmpty)
        guard case .runCompleted = events.last else { Issue.record("末事件应为 RunCompleted"); return }
        // 工具轮 + 收束轮
        #expect(client.calls == 2)
    }
}

/// 工具函数单测（截断/片段/周次格式化/Manifest）。
@Suite("AgentHelpers")
struct AgentHelpersTests {
    @Test("clipUtf8 按 UTF-8 字节截断不破坏多字节字符")
    func clipUtf8() {
        let text = "喵" * 5000  // 每个字符 3 字节
        let clipped = AgentLoop.clipUtf8(text, limit: 100)
        #expect(clipped.utf8.count <= 100)
        #expect(clipped.hasSuffix(AgentLoop.truncatedSuffix))
        #expect(!clipped.dropLast(AgentLoop.truncatedSuffix.count).isEmpty)
        let ascii = AgentLoop.clipUtf8("abc", limit: 100)
        #expect(ascii == "abc")
    }

    @Test("snippet 提取关键词附近片段")
    func snippetExtraction() {
        let content = String(repeating: "前文。", count: 50) + "本次考试报名时间确定" + String(repeating: "后文。", count: 50)
        let snippet = AgentTools.selfSnippet(content, "考试报名")
        #expect(snippet?.contains("…") == true)
        #expect(snippet?.contains("考试报名") == true)
        #expect(AgentTools.selfSnippet(content, "不存在的词") == nil)
    }

    @Test("formatWeeks：每周/单周/双周/区间")
    func weekFormatting() {
        #expect(AgentTools.formatWeeks([], 16) == "周次未指定")
        #expect(AgentTools.formatWeeks(Set(1...16), 16) == "每周")
        #expect(AgentTools.formatWeeks(Set([1, 3, 5, 7, 9, 11, 13, 15]), 16) == "单周")
        #expect(AgentTools.formatWeeks(Set([2, 4, 6, 8, 10, 12, 14, 16]), 16) == "双周")
        #expect(AgentTools.formatWeeks(Set([1, 2, 3, 8]), 16) == "1-3、8 周")
    }

    @Test("parseChunk 解析 SSE 帧")
    func chunkParsing() {
        let data = #"{"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}"#
        let deltas = OpenAiCompatibleClient.parseChunk(data)
        guard case .text(let value)? = deltas.first else {
            Issue.record("应为 text delta")
            return
        }
        #expect(value == "你好")

        let toolData = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"search_notices","arguments":"{\"q\""}}]}}]}"#
        let toolDeltas = OpenAiCompatibleClient.parseChunk(toolData)
        guard case .toolCallDelta(let index, let id, let name, let chunk)? = toolDeltas.first else {
            Issue.record("应为 toolCallDelta")
            return
        }
        #expect(index == 0 && id == "c1" && name == "search_notices" && chunk == #"{"q""#)
    }
}

private extension String {
    static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}
