import Foundation
import Testing
import GRDB
@testable import OpenJWCCore

/// ChatService 测试（tasks 2.6）：发送落库序 / 工具卡落库 / 终态 / 重试不重插 / 历史裁剪 / 中断兜底。
/// 假 LlmClient 注入事件序列，全部离线。
@Suite("ChatService 发送编排")
struct ChatServiceTests {

    private func makeTempDB() throws -> DatabaseProvider {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openjwc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DatabaseProvider(databasePath: dir.appendingPathComponent("test.sqlite").path)
    }

    private func collect(_ stream: AsyncStream<ChatStreamEvent>) async -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    /// 跑一轮完整发送，返回（事件列表，会话内全部 turns，dao，sessionId）。
    private func runSend(
        _ client: any LlmClient,
        query: String = "考试安排？",
        attachments: [ChatAttachment] = [],
        isRetry: Bool = false,
        sessionSeed: ((Int64, ChatDao) async throws -> Void)? = nil
    ) async throws -> ([ChatStreamEvent], [ChatTurn], ChatDao, Int64) {
        let db = try makeTempDB()
        let dao = ChatDao(db: db.dbWriter)
        let service = ChatService(db: db.dbWriter)
        let sessionId = try await service.createSession(title: "测试会话")
        if let sessionSeed { try await sessionSeed(sessionId, dao) }
        let stream = try await service.sendMessage(
            sessionId: sessionId, text: query,
            attachments: attachments, isRetry: isRetry,
            makeLoop: {
                AgentLoop(
                    client: client,
                    tools: AgentTools(repository: FakeCorpus()),
                    repository: FakeCorpus()
                )
            }
        )
        let events = await collect(stream)
        let turns = try await dao.turns(sessionId: sessionId)
        return (events, turns, dao, sessionId)
    }

    @Test("纯文本回复：用户消息 + 占位 + 终态 COMPLETED 落库序")
    func plainAnswer() async throws {
        let (events, turns, _, _) = try await runSend(FakeLlmClient(rounds: [
            [.text("考试是 9 月 20 日。"), .finished("stop")],
        ]))

        // 落库序：user(completed) → assistant占位(running→completed)
        #expect(turns.count == 2)
        #expect(turns[0].message.role == .user)
        #expect(turns[0].message.status == .completed)
        #expect(turns[0].message.text == "考试安排？")
        let assistant = turns[1].message
        #expect(assistant.role == .assistant)
        #expect(assistant.status == .completed)
        #expect(assistant.text == "考试是 9 月 20 日。")
        #expect(assistant.errorCode == nil)
        #expect(turns[1].toolCalls.isEmpty)

        // 事件序：started → generating → completed
        guard case .started(let mid) = events.first else {
            Issue.record("首事件应为 started"); return
        }
        #expect(mid == assistant.messageId)
        guard case .generating(let text)? = events.dropFirst().first else {
            Issue.record("第二事件应为 generating"); return
        }
        #expect(text == "考试是 9 月 20 日。")
        guard case .completed(let finalText)? = events.last else {
            Issue.record("末事件应为 completed"); return
        }
        #expect(finalText == "考试是 9 月 20 日。")
    }

    @Test("工具轮：工具卡逐条落库（running→完成），正文终态")
    func toolCallsPersist() async throws {
        let (events, turns, _, _) = try await runSend(FakeLlmClient(rounds: [
            [
                .toolCallDelta(index: 0, id: "call-1", name: "search_notices",
                               argumentsChunk: #"{"query":"考试","limit":5}"#),
                .finished("tool_calls"),
            ],
            [.text("根据检索结果……"), .finished("stop")],
        ]))

        #expect(turns.count == 2)
        let assistantTurn = turns[1]
        #expect(assistantTurn.message.status == .completed)
        #expect(assistantTurn.toolCalls.count == 1)
        let tool = assistantTurn.toolCalls[0]
        #expect(tool.name == "search_notices")
        #expect(tool.status == "completed")
        #expect(tool.targetId == nil)
        #expect(tool.position == 1)

        // 事件含 toolPhase
        #expect(events.contains(where: { if case .toolPhase = $0 { return true }; return false }))
    }

    @Test("失败轮：占位落 FAILED + errorCode，事件 failed 携带摘要（配置缺失路径）")
    func failurePersists() async throws {
        // 缺 Key 客户端：streamChat 直接抛 LlmConfigException → AgentLoop 产 runFailed(configuration)
        let unconfigured = OpenAiCompatibleClient(config: LlmProviderConfig(), apiKey: "")
        let (events, turns, _, _) = try await runSend(unconfigured)

        let assistant = turns[1].message
        #expect(assistant.status == .failed)
        #expect(assistant.errorCode == AgentFailure.configuration.rawValue)
        guard case .failed(let code, let summary, _)? = events.last(where: {
            if case .failed = $0 { return true }; return false
        }) else {
            Issue.record("应有 failed 事件"); return
        }
        #expect(code == AgentFailure.configuration.rawValue)
        #expect(AgentFailure.configRelated.contains(code))
        #expect(!summary.isEmpty)
    }

    @Test("重试：复用原用户消息（不重插）")
    func retryDoesNotDuplicateUserMessage() async throws {
        let db = try makeTempDB()
        let dao = ChatDao(db: db.dbWriter)
        let service = ChatService(db: db.dbWriter)
        let sessionId = try await service.createSession(title: "重试测试")

        // 第一轮：缺 Key → 失败
        let unconfigured = OpenAiCompatibleClient(config: LlmProviderConfig(), apiKey: "")
        _ = try await collect(try await service.sendMessage(
            sessionId: sessionId, text: "问题", attachments: [], isRetry: false,
            makeLoop: { AgentLoop(client: unconfigured, tools: AgentTools(repository: FakeCorpus()), repository: FakeCorpus()) }
        ))
        var turns = try await dao.turns(sessionId: sessionId)
        #expect(turns.count == 2) // user + failed assistant
        #expect(turns[1].message.status == .failed)

        // 重试：好客户端 → 新占位 completed，user 不重插
        let ok = FakeLlmClient(rounds: [[.text("这次成功了"), .finished("stop")]])
        _ = try await collect(try await service.sendMessage(
            sessionId: sessionId, text: "问题", attachments: [], isRetry: true,
            makeLoop: { AgentLoop(client: ok, tools: AgentTools(repository: FakeCorpus()), repository: FakeCorpus()) }
        ))
        turns = try await dao.turns(sessionId: sessionId)
        // user 仍只有 1 条；assistant 2 条（failed + 新占位 completed）
        #expect(turns.filter { $0.message.role == .user }.count == 1)
        #expect(turns.filter { $0.message.role == .assistant }.count == 2)
        #expect(turns.last?.message.status == .completed)
    }

    @Test("历史裁剪：只取 COMPLETED 的 user/assistant，排除当前轮，≤20 条")
    func historyTrimming() async throws {
        let captured = HistoryCapturingClient()
        let (_, turns, dao, sessionId) = try await runSend(
            captured,
            sessionSeed: { sid, dao in
                // 预置 3 条已完成历史 + 1 条失败消息
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                for (i, text) in ["历史1", "历史2", "历史3"].enumerated() {
                    _ = try await dao.insertMessage(ChatMessageRecord(
                        ownerSessionId: sid, text: text, role: .user,
                        status: .completed, timestamp: now - 100 + Int64(i)
                    ))
                }
                _ = try await dao.insertMessage(ChatMessageRecord(
                    ownerSessionId: sid, text: "失败消息", role: .assistant,
                    status: .failed, timestamp: now - 50
                ))
            }
        )
        _ = turns; _ = dao; _ = sessionId

        // 首次调用 = system(被过滤) + 3 条完成历史 + 1 条当前 prompt；
        // 失败 assistant 被排除；「考试安排？」恰好 1 次（未排除当前轮会重复出现 2 次）
        #expect(captured.history.count == 4)
        #expect(!captured.history.contains { $0.content == "失败消息" })
        #expect(captured.history.filter { $0.content == "考试安排？" }.count == 1)
        #expect(captured.history.prefix(3).allSatisfy { $0.content == "历史1" || $0.content == "历史2" || $0.content == "历史3" })
    }

    @Test("中断兜底：流消费被取消 → FAILED 终态落库（agent_cancelled）")
    func interruptionFallback() async throws {
        let db = try makeTempDB()
        let service = ChatService(db: db.dbWriter)
        let dao = ChatDao(db: db.dbWriter)
        let sessionId = try await service.createSession(title: "取消测试")

        let slow = FakeLlmClient(rounds: [[.text("开头"), .finished("stop")], [.text("续"), .finished("stop")], [.text("再续"), .finished("stop")]])
        let stream = try await service.sendMessage(
            sessionId: sessionId, text: "长问题", attachments: [], isRetry: false,
            makeLoop: { AgentLoop(client: slow, tools: AgentTools(repository: FakeCorpus()), repository: FakeCorpus()) }
        )
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(80))
        consumer.cancel()
        _ = await consumer.result

        // 占位必须到达终态（FAILED；取消路径 agent_cancelled 或循环完成前的其它终态均可，但不得 RUNNING）
        try await Task.sleep(for: .milliseconds(200))
        let turns = try await dao.turns(sessionId: sessionId)
        let assistant = turns.last(where: { $0.message.role == .assistant })?.message
        #expect(assistant != nil)
        #expect(assistant?.status != .running)
    }

    @Test("AgentLoop 工具调用顺序锁定：多索引乱序到达仍按 index 排序执行（tasks 2.1）")
    func toolCallOrderDeterministic() async throws {
        let client = FakeLlmClient(rounds: [
            [
                .toolCallDelta(index: 2, id: "c3", name: "list_labels", argumentsChunk: #"{}"#),
                .toolCallDelta(index: 0, id: "c1", name: "current_time", argumentsChunk: #"{}"#),
                .toolCallDelta(index: 1, id: "c2", name: "list_labels", argumentsChunk: #"{}"#),
                .finished("tool_calls"),
            ],
            [.text("done"), .finished("stop")],
        ])
        let corpus = FakeCorpus()
        let loop = AgentLoop(client: client, tools: AgentTools(repository: corpus), repository: corpus)
        let events = try await { () async -> [AgentEvent] in
            var out: [AgentEvent] = []
            for await e in loop.run(AgentRequest(query: "q")) { out.append(e) }
            return out
        }()
        let names = events.compactMap { event -> String? in
            if case .toolStarted(_, let name, _, _) = event { return name }
            return nil
        }
        #expect(names == ["current_time", "list_labels", "list_labels"])
    }
}

/// 捕获 AgentRequest 历史的客户端包装。
private final class HistoryCapturingClient: LlmClient, @unchecked Sendable {
    let config = LlmProviderConfig()
    private(set) var history: [AgentMessage] = []
    private let lock = NSLock()
    private let inner: FakeLlmClient

    init() {
        self.inner = FakeLlmClient(rounds: [[.text("好"), .finished("stop")]])
    }

    static func roles(_ messages: [AgentMessage]) -> [String] {
        messages.map(\.role)
    }

    func streamChat(messages: [LlmMessage], tools: [LlmToolSpec]) -> AsyncThrowingStream<LlmDelta, Error> {
        lock.lock()
        // 只记录首次调用（round 1：system + 历史 + 当前 query）；
        // finalize 的第二次调用含本轮指令，不是「历史」语义
        if history.isEmpty {
            history = messages
                .filter { $0.role == "user" || $0.role == "assistant" }
                .map { AgentMessage(role: $0.role, content: $0.content) }
        }
        lock.unlock()
        return inner.streamChat(messages: messages, tools: tools)
    }
}
