import Foundation
import Testing
import GRDB
@testable import OpenJWCCore

/// 复刻用户实测场景：真实 GrdbNoticeCorpus（非 FakeCorpus）+ 带正文的真实 id。
/// 用户反馈：模型每轮只复读第一篇的标题链接。验证真实链路 system prompt 是否含 excerpt。
@Suite("引用真实链路诊断")
struct AttachmentRealChainTests {

    private final class FullCapturingClient: LlmClient, @unchecked Sendable {
        let config = LlmProviderConfig()
        private(set) var systemPrompt = ""
        private(set) var allMessages: [LlmMessage] = []
        private let lock = NSLock()
        private let inner: FakeLlmClient

        init() {
            self.inner = FakeLlmClient(rounds: [
                [
                    .toolCallDelta(index: 0, id: "c1", name: "read_notice",
                                   argumentsChunk: #"{"id":"REAL-1"}"#),
                    .finished("tool_calls"),
                ],
                [.text("基于全文的总结"), .finished("stop")],
                [.text("最终"), .finished("stop")],
                [.text("最终x") , .finished("stop")],
            ])
        }

        func streamChat(messages: [LlmMessage], tools: [LlmToolSpec]) -> AsyncThrowingStream<LlmDelta, Error> {
            lock.lock()
            if systemPrompt.isEmpty {
                systemPrompt = messages.first(where: { $0.role == "system" })?.content ?? ""
            }
            allMessages.append(contentsOf: messages)
            lock.unlock()
            return inner.streamChat(messages: messages, tools: tools)
        }
    }

    @Test("真实 DAO 链路：引用块含正文，read_notice 返回正文")
    func realChain() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openjwc-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try DatabaseProvider(databasePath: dir.appendingPathComponent("t.sqlite").path)

        // 预置真实 notice（867 字正文，模拟用户场景）
        let content = String(repeating: "学校于8月26日组织了暑期本科教学工作会议，部署新学期安排。", count: 30)
        try await NoticeDao(db: db.dbWriter).upsertAll([
            NoticeRecord(
                id: "REAL-1", sourceId: "seu-jwc", label: "教务信息",
                title: "东南大学党委书记邬小撑调研检查暑期学校本科教学工作",
                publishedAt: 1_756_200_000_000, publishedDay: "2026-08-27",
                detailUrl: "https://jwc.seu.edu.cn/2026/0827/c1493a624557/page.htm",
                isPage: true, content: content, contentVersion: 1,
                attachments: nil, fetchedAt: 1, notified: false, favorite: false
            )
        ])
        try await SourceDao(db: db.dbWriter).upsert(NoticeSourceRecord(
            id: "seu-jwc", name: "东南大学教务处", version: "1", origin: "builtin",
            scriptFile: nil, domains: JSONStringList([]), labels: JSONStringList(["教务信息"]),
            scheduleMinutes: 360, subscribed: true, lastRunAt: nil, lastCount: 0, lastError: nil
        ))

        let captured = FullCapturingClient()
        let service = ChatService(db: db.dbWriter)
        let sessionId = try await service.createSession(title: "真实链路")
        let stream = try await service.sendMessage(
            sessionId: sessionId, text: "这篇写了什么",
            attachments: [ChatAttachment(id: "REAL-1", title: "邬小撑调研")],
            isRetry: false,
            makeLoop: {
                let corpus = GrdbNoticeCorpus(db: db.dbWriter)
                return AgentLoop(client: captured, tools: AgentTools(repository: corpus), repository: corpus)
            }
        )
        var events: [ChatStreamEvent] = []
        for await event in stream { events.append(event) }

        let refStart = captured.systemPrompt.range(of: "【引用的资讯】")
        let refBlock = refStart.map { String(captured.systemPrompt[$0.lowerBound...]) } ?? "(无引用块)"
        print("[real] system 长度=\(captured.systemPrompt.count)")
        print("[real] 引用块=\(refBlock.prefix(400))")
        let readCall = captured.allMessages.first(where: { $0.role == "tool" })?.content ?? "(无工具结果)"
        print("[real] read_notice 结果前120=\(readCall.prefix(120))")
        print("[real] 事件数=\(events.count) 末事件=\(String(describing: events.last))")

        #expect(captured.systemPrompt.contains("【引用的资讯】"))
        #expect(captured.systemPrompt.contains("暑期本科教学工作会议")) // excerpt 在 system
        #expect(readCall.contains("暑期本科教学工作会议")) // read_notice 全文可读
    }
}
