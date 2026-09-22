import Foundation
import GRDB
import OpenJWCCore

/// 聊天 UI 状态机（对齐 Android ChatViewModel）：
/// 会话状态 Map + 流式正文 + 失败轮缓存 + 当前会话的 turns 观察。
@MainActor
@Observable
final class ChatStore {
    /// 单会话运行状态（对齐 Android ChatSessionState）。
    enum SessionState: Equatable {
        case idle, loading, generating, toolCalling, error(String)
    }

    /// 失败轮缓存（重试复用；对齐 Android FailedTurn）。
    struct FailedTurn: Equatable {
        var text: String
        var attachments: [ChatAttachment]
        var code: String
        var summary: String
    }

    // MARK: - 观察数据

    /// 会话列表（ValueObservation 驱动）。
    private(set) var sessions: [ChatSessionRecord] = []
    /// 当前会话的消息轮（ValueObservation 驱动；新聊天态为空）。
    private(set) var turns: [ChatTurn] = []

    // MARK: - 运行态

    /// 每会话状态（含历史会话的还原态：message RUNNING → generating 等）。
    private(set) var sessionStates: [Int64: SessionState] = [:]
    /// 当前会话 id；nil = 新聊天态。
    var currentSessionId: Int64?
    /// 当前会话的流式正文（与 turns 分离，100ms 合并写入，避免整列表失效）。
    private(set) var streamingText = ""
    /// 当前会话的失败轮（重试行数据源）。
    private(set) var failedTurn: FailedTurn?
    /// 附件（发送前暂存）。
    var attachments: [ChatAttachment] = []
    /// 输入文本（截断 10000 字）。
    var inputText = "" {
        didSet {
            if inputText.count > Self.maxInputLength {
                inputText = String(inputText.prefix(Self.maxInputLength))
            }
        }
    }

    static let maxInputLength = 10_000

    private let chatDao: ChatDao
    private let service: ChatService
    private let runtime: AgentRuntime
    private let db: any DatabaseWriter
    private var sessionsObservation: (any DatabaseCancellable)?
    private var turnsObservation: (any DatabaseCancellable)?
    /// 进行中的发送任务（停止键取消）。
    private var sendTask: Task<Void, Never>?

    init(db: any DatabaseWriter, runtime: AgentRuntime) {
        self.chatDao = ChatDao(db: db)
        self.db = db
        let service = ChatService(db: db)
        self.service = service
        self.runtime = runtime
        startSessionsObservation()
    }

    // MARK: - 当前会话派生

    var currentSessionTitle: String? {
        sessions.first { $0.sessionId == currentSessionId }?.title
    }

    /// 当前会话状态（新聊天态 = idle）。
    var currentState: SessionState {
        guard let id = currentSessionId else { return .idle }
        return sessionStates[id] ?? restoredState(for: id)
    }

    var isGenerating: Bool {
        switch currentState {
        case .loading, .generating, .toolCalling: return true
        default: return false
        }
    }

    /// 从 DB 还原历史会话状态（RUNNING 消息残留 = 上次进程中断）。
    private func restoredState(for sessionId: Int64) -> SessionState {
        if let last = turns.last, last.message.status == .running {
            return .error("上次生成被中断")
        }
        return .idle
    }

    // MARK: - 会话管理

    func loadSession(_ id: Int64) {
        currentSessionId = id
        failedTurn = nil
        streamingText = ""
        restartTurnsObservation()
    }

    func startNewChat() {
        currentSessionId = nil
        failedTurn = nil
        streamingText = ""
        turns = []
        restartTurnsObservation()
    }

    func renameSession(_ id: Int64, title: String) async {
        guard var meta = sessions.first(where: { $0.sessionId == id }) else { return }
        meta.title = title
        try? await chatDao.updateMetadata(meta)
    }

    func deleteSession(_ id: Int64) async {
        try? await chatDao.deleteSession(sessionId: id)
        if currentSessionId == id {
            startNewChat()
        }
    }

    // MARK: - 附件

    func addAttachment(_ attachment: ChatAttachment) {
        attachments.append(attachment)
    }

    func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    // MARK: - 发送 / 停止 / 重试

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        inputText = ""
        let currentAttachments = attachments
        attachments = []

        let sessionId: Int64
        if let id = currentSessionId {
            sessionId = id
        } else {
            // 首条消息建会话：标题 = 前 20 字去换行
            let title = text.replacingOccurrences(of: "\n", with: " ")
            let trimmed = String(title.prefix(20))
            sessionId = (try? await service.createSession(title: trimmed)) ?? 0
            currentSessionId = sessionId
            restartTurnsObservation()
        }

        failedTurn = nil
        sessionStates[sessionId] = .loading
        streamingText = ""

        let service = self.service
        let makeLoop = runtime.makeLoop
        sendTask = Task { [weak self] in
            guard let stream = try? await service.sendMessage(
                sessionId: sessionId, text: text,
                attachments: currentAttachments, isRetry: false,
                makeLoop: makeLoop
            ) else {
                self?.markFailed(sessionId, code: "agent_failed", summary: "发送失败", partial: "")
                return
            }
            await self?.consume(stream, sessionId: sessionId)
        }
    }

    /// 停止当前生成（D-12：发送键原位切换；取消 → agent_cancelled → 失败路径）。
    func stopGenerating() {
        sendTask?.cancel()
        sendTask = nil
    }

    /// 重试失败轮（复用原文本与附件；不重复插用户消息）。
    func retryLastMessage() async {
        guard let failed = failedTurn, let sessionId = currentSessionId, !isGenerating else { return }
        failedTurn = nil
        sessionStates[sessionId] = .loading
        streamingText = ""

        let service = self.service
        let makeLoop = runtime.makeLoop
        sendTask = Task { [weak self] in
            guard let stream = try? await service.sendMessage(
                sessionId: sessionId, text: failed.text,
                attachments: failed.attachments, isRetry: true,
                makeLoop: makeLoop
            ) else {
                self?.markFailed(sessionId, code: "agent_failed", summary: "重试失败", partial: "")
                return
            }
            await self?.consume(stream, sessionId: sessionId)
        }
    }

    // MARK: - 事件消费

    private func consume(_ stream: AsyncStream<ChatStreamEvent>, sessionId: Int64) async {
        for await event in stream {
            guard !Task.isCancelled else { return }
            switch event {
            case .started:
                sessionStates[sessionId] = .loading
            case .toolPhase:
                sessionStates[sessionId] = .toolCalling
            case .generating(let text):
                sessionStates[sessionId] = .generating
                streamingText = text
            case .completed(let finalText):
                sessionStates[sessionId] = .idle
                streamingText = ""
                _ = finalText
            case .failed(let code, let summary, let partial):
                markFailed(sessionId, code: code, summary: summary, partial: partial)
            }
        }
        if sendTask?.isCancelled == true { sendTask = nil }
    }

    private func markFailed(_ sessionId: Int64, code: String, summary: String, partial: String) {
        sessionStates[sessionId] = .error(summary)
        // 停止/失败保留部分正文（观察会带出落库的部分文本）；失败轮供重试
        failedTurn = FailedTurn(
            text: lastUserText() ?? "",
            attachments: [],
            code: code,
            summary: summary
        )
        if partial.isEmpty { streamingText = "" }
    }

    private func lastUserText() -> String? {
        turns.last(where: { $0.message.role == .user })?.message.text
    }

    // MARK: - 观察桥接（D-2：单闭包多表组装）

    private func startSessionsObservation() {
        let observation = ValueObservation.tracking { db in
            try ChatDao.allSessionsSync(db)
        }
        .removeDuplicates()
        sessionsObservation = observation.start(in: db, onError: { NSLog("ChatStore sessions 观察错误: \($0)") }) { [weak self] value in
            Task { @MainActor in self?.sessions = value }
        }
    }

    private func restartTurnsObservation() {
        turnsObservation?.cancel()
        turnsObservation = nil
        guard let sessionId = currentSessionId else {
            turns = []
            return
        }
        let observation = ValueObservation.tracking { db in
            try ChatDao.turnsSync(db, sessionId: sessionId)
        }
        turnsObservation = observation.start(in: db, onError: { NSLog("ChatStore turns 观察错误: \($0)") }) { [weak self] value in
            Task { @MainActor in self?.turns = value }
        }
    }
}
