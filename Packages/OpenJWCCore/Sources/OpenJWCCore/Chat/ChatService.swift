import Foundation
import GRDB

/// 聊天发送时随消息引用的资讯附件。
public struct ChatAttachment: Sendable, Equatable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// 聊天发送编排对外的事件流（对齐 Android ChatStreamStatus 的信息面）。
/// UI（ChatStore）据此驱动会话状态机；数据库写入全部由本服务内部完成。
public enum ChatStreamEvent: Sendable {
    /// 一轮开始（assistantMessageId = 占位消息行 id）。
    case started(assistantMessageId: Int64)
    /// 进入工具轮（UI 切 ToolCalling 态；具体卡片由 turns 观察驱动）。
    case toolPhase
    /// 流式正文（**累积全文**，UI 直接替换显示）。
    case generating(text: String)
    /// 本轮成功完成（finalText 已落库）。
    case completed(finalText: String)
    /// 本轮失败（占位已落 FAILED + code；partialText 为停止/失败前已生成部分）。
    case failed(code: String, summary: String, partialText: String)
}

/// 聊天发送编排（对齐 Android `ChatRepository.sendMessage`）：用户消息 + assistant 占位落库 →
/// Agent 循环逐事件落库（runId / 工具卡 / 终态）→ 事件流驱动 UI。
/// 历史裁剪：只取 COMPLETED 的 user/assistant，≤20 条、≤48KB，排除当前轮用户消息。
public final class ChatService: Sendable {
    /// 对话历史条数与字节预算（对齐 Android ChatRepository）。
    private static let maxHistoryMessages = 20
    private static let maxHistoryBytes = 48 * 1024

    private let dao: ChatDao

    public init(db: any DatabaseWriter) {
        self.dao = ChatDao(db: db)
    }

    /// 新建会话；返回 sessionId。
    public func createSession(title: String) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return try await dao.insertMetadata(ChatSessionRecord(
            sessionId: nil, title: title, lastUpdated: now
        ))
    }

    /// 发送一轮：插入用户消息（isRetry 复用原消息不重插）→ assistant 占位 → Agent 循环。
    /// `makeLoop` 每次发送调用一次（UI 侧按当前 LLM 配置组装，改配置立即生效）。
    /// 消费侧取消 Task → AgentLoop 产出 runFailed(agent_cancelled) → 落 FAILED 终态。
    public func sendMessage(
        sessionId: Int64,
        text: String,
        attachments: [ChatAttachment],
        isRetry: Bool = false,
        makeLoop: @escaping @Sendable () -> AgentLoop
    ) async throws -> AsyncStream<ChatStreamEvent> {
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        // retry 复用原用户消息：只推进 lastUpdated，不重插
        var currentUserMessageId: Int64?
        if !isRetry {
            let userId = try await dao.insertMessage(ChatMessageRecord(
                ownerSessionId: sessionId,
                text: text,
                role: .user,
                attachmentTitles: JSONStringList(attachments.map(\.title)),
                attachmentIds: JSONStringList(attachments.map(\.id)),
                status: .completed,
                timestamp: now
            ))
            currentUserMessageId = userId
        } else {
            // 重试：排除历史中最后一条 user 消息（即本次 query 原文）
            let msgs = try await dao.messages(sessionId: sessionId)
            currentUserMessageId = msgs.last(where: { $0.role == .user })?.messageId
        }
        try await dao.updateLastUpdated(sessionId: sessionId, timestamp: now)

        let assistantMessageId = try await dao.insertMessage(ChatMessageRecord(
            ownerSessionId: sessionId,
            text: "",
            role: .assistant,
            status: .running,
            timestamp: now + 1
        ))

        // 历史在插入占位后构建：占位是 RUNNING 天然被过滤；当前轮用户消息按 id 排除
        let history = try await buildHistory(
            sessionId: sessionId, excluding: currentUserMessageId
        )

        let request = AgentRequest(
            query: text,
            history: history,
            noticeIds: attachments.map(\.id)
        )

        return AsyncStream(ChatStreamEvent.self, bufferingPolicy: .unbounded) { continuation in
            let task = Task { [dao] in
                let loop = makeLoop()
                var accumulated = ""
                var lastDelivery: String?
                var sawTerminal = false
                var toolRowIds: [String: Int64] = [:]
                var toolPosition = 0
                var sawTool = false

                for await event in loop.run(request) {
                    switch event {
                    case .runStarted(let runId):
                        try? await dao.updateMessageRunId(messageId: assistantMessageId, runId: runId)
                        await continuation.yield(.started(assistantMessageId: assistantMessageId))
                    case .toolStarted(let toolId, let name, let summary, let targetId):
                        toolPosition += 1
                        let rowId = (try? await dao.insertToolCall(ChatToolCallRecord(
                            messageId: assistantMessageId,
                            position: toolPosition,
                            name: name,
                            summary: summary,
                            status: "running",
                            targetId: targetId
                        ))) ?? 0
                        toolRowIds[toolId] = rowId
                        if !sawTool {
                            sawTool = true
                            await continuation.yield(.toolPhase)
                        }
                    case .toolCompleted(let toolId, _, let status, let durationMs, let code):
                        if let rowId = toolRowIds[toolId] {
                            try? await dao.completeToolCall(
                                id: rowId, status: status, code: code, durationMs: durationMs
                            )
                        }
                    case .answerDelta(let delta, let delivery):
                        accumulated += delta
                        lastDelivery = delivery
                        await continuation.yield(.generating(text: accumulated))
                    case .runCompleted:
                        sawTerminal = true
                        try? await dao.finishMessage(
                            messageId: assistantMessageId,
                            text: accumulated,
                            status: .completed,
                            delivery: lastDelivery,
                            errorCode: nil
                        )
                        await continuation.yield(.completed(finalText: accumulated))
                    case .runFailed(_, let code, let summary):
                        sawTerminal = true
                        try? await dao.finishMessage(
                            messageId: assistantMessageId,
                            text: accumulated,
                            status: .failed,
                            delivery: nil,
                            errorCode: code
                        )
                        await continuation.yield(.failed(
                            code: code, summary: summary, partialText: accumulated
                        ))
                    }
                }

                // 兜底：循环结束但未见终态事件（理论不可达；防御进程级异常后的 RUNNING 残留）
                if !sawTerminal {
                    try? await dao.finishMessage(
                        messageId: assistantMessageId,
                        text: accumulated,
                        status: .failed,
                        delivery: nil,
                        errorCode: "agent_interrupted"
                    )
                    await continuation.yield(.failed(
                        code: "agent_interrupted",
                        summary: AgentFailure.failed.summary,
                        partialText: accumulated
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 历史：COMPLETED 的 user/assistant，从新到旧取 ≤20 条、≤48KB，排除当前轮用户消息；
    /// 返回时间正序（对齐 Android buildHistory 语义）。
    private func buildHistory(sessionId: Int64, excluding currentUserMessageId: Int64?) async throws -> [AgentMessage] {
        let all = try await dao.messages(sessionId: sessionId)
        let candidates = all.filter { message in
            guard message.status == .completed,
                  message.role == .user || message.role == .assistant,
                  message.messageId != currentUserMessageId else { return false }
            return true
        }
        var picked: [ChatMessageRecord] = []
        var totalBytes = 0
        for message in candidates.reversed() {
            let bytes = message.text.utf8.count
            if picked.count >= Self.maxHistoryMessages { break }
            if totalBytes + bytes > Self.maxHistoryBytes { break }
            picked.append(message)
            totalBytes += bytes
        }
        return picked.reversed().map { record in
            AgentMessage(
                role: record.role == .user ? "user" : "assistant",
                content: record.text,
                attachmentIds: record.attachmentIds.value
            )
        }
    }
}
