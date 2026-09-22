import Foundation
import Testing
import GRDB
@testable import OpenJWCCore

/// 复现：引用附件是否进入 system prompt（用户反馈「AI 说没有发现引用」）。
@Suite("引用附件传递诊断")
struct AttachmentPromptTests {

    /// 捕获全部消息（含 system）的客户端。
    private final class SystemCapturingClient: LlmClient, @unchecked Sendable {
        let config = LlmProviderConfig()
        private(set) var systemPrompt = ""
        private(set) var userPrompt = ""
        private let lock = NSLock()
        private let inner: FakeLlmClient

        init() {
            self.inner = FakeLlmClient(rounds: [[.text("收到"), .finished("stop")]])
        }

        func streamChat(messages: [LlmMessage], tools: [LlmToolSpec]) -> AsyncThrowingStream<LlmDelta, Error> {
            lock.lock()
            if systemPrompt.isEmpty {
                systemPrompt = messages.first(where: { $0.role == "system" })?.content ?? ""
                userPrompt = messages.last(where: { $0.role == "user" })?.content ?? ""
            }
            lock.unlock()
            return inner.streamChat(messages: messages, tools: tools)
        }
    }

    @Test("sendMessage 带附件 → system prompt 应含「引用的资讯」块与正文")
    func attachmentsReachSystemPrompt() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openjwc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try DatabaseProvider(databasePath: dir.appendingPathComponent("t.sqlite").path)
        let service = ChatService(db: db.dbWriter)
        let sessionId = try await service.createSession(title: "引用测试")

        let captured = SystemCapturingClient()
        let corpus = FakeCorpus() // notice-1「关于期末考试安排的通知」正文「考试时间：2026-09-20。」

        let stream = try await service.sendMessage(
            sessionId: sessionId, text: "这条通知说了什么",
            attachments: [ChatAttachment(id: "notice-1", title: "关于期末考试安排的通知")],
            isRetry: false,
            makeLoop: {
                AgentLoop(
                    client: captured,
                    tools: AgentTools(repository: corpus),
                    repository: corpus
                )
            }
        )
        for await _ in stream {}

        print("[diag] system 长度=\(captured.systemPrompt.count)")
        print("[diag] system 含引用块=\(captured.systemPrompt.contains("引用的资讯"))")
        print("[diag] system 含标题=\(captured.systemPrompt.contains("关于期末考试安排的通知"))")
        print("[diag] system 含正文=\(captured.systemPrompt.contains("考试时间"))")
        print("[diag] user=\(captured.userPrompt.prefix(80))")

        #expect(captured.systemPrompt.contains("引用的资讯"))
        #expect(captured.systemPrompt.contains("关于期末考试安排的通知"))
        #expect(captured.systemPrompt.contains("考试时间"))
    }
}
