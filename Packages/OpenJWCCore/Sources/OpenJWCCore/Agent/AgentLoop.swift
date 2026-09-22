import Foundation

/// 本地 Agent 循环（与后端 `internal/service/agent/loop.go` 同构，逐行直译 Android AgentLoop.kt）：
/// 系统提示 + 元数据 + 历史 → 多轮「模型（带工具）→ 执行工具 → 观察」→
/// 最后用一次**禁用工具**的流式请求产出最终答案（工具轮正文不公开）。
public final class AgentLoop: Sendable {
    public static let truncatedSuffix = "\n[内容已截断]"

    private let client: any LlmClient
    private let tools: AgentTools
    private let repository: any NoticeCorpus
    private let budget: AgentBudget
    private let timeZone: TimeZone

    public init(
        client: any LlmClient,
        tools: AgentTools,
        repository: any NoticeCorpus,
        budget: AgentBudget = AgentBudget(),
        timeZone: TimeZone = .current
    ) {
        self.client = client
        self.tools = tools
        self.repository = repository
        self.budget = budget
        self.timeZone = timeZone
    }

    /// 事件流。失败不抛出，而是产出 runFailed 事件（对齐 Android Flow 语义）。
    public func run(_ request: AgentRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                let runId = UUID().uuidString.prefix(8).description
                continuation.yield(.runStarted(runId: runId))
                do {
                    try await execute(request, runId: runId) { continuation.yield($0) }
                } catch let error as LlmConfigException {
                    continuation.yield(.runFailed(
                        runId: runId, code: AgentFailure.configuration.rawValue,
                        summary: AgentFailure.configuration.summary
                    ))
                } catch let error as LlmHttpException {
                    let failure = AgentFailure.fromHttpStatus(error.status)
                    continuation.yield(.runFailed(runId: runId, code: failure.rawValue, summary: failure.summary))
                } catch is CancellationError {
                    // 外部取消：向上传播（Swift 的取消通过 Task.isCancelled 检查）
                    continuation.yield(.runFailed(
                        runId: runId, code: AgentFailure.cancelled.rawValue,
                        summary: AgentFailure.cancelled.summary
                    ))
                } catch is AgentRunTimeoutError {
                    continuation.yield(.runFailed(
                        runId: runId, code: AgentFailure.timeout.rawValue,
                        summary: AgentFailure.timeout.summary
                    ))
                } catch {
                    continuation.yield(.runFailed(
                        runId: runId, code: AgentFailure.failed.rawValue,
                        summary: AgentFailure.failed.summary
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 便捷入口：只收集最终答案（日报这类批量任务用）。失败时抛出 AgentRunFailedException。
    public func answer(_ request: AgentRequest) async throws -> String {
        var builder = ""
        var failure: (code: String, summary: String)?
        for await event in run(request) {
            switch event {
            case .answerDelta(let text, _):
                builder += text
            case .runFailed(let runId, let code, let summary):
                failure = (code, summary)
            default:
                break
            }
        }
        if let failure {
            throw AgentRunFailedException(code: failure.code, summary: failure.summary)
        }
        return builder
    }

    private func execute(
        _ request: AgentRequest,
        runId: String,
        emit: @escaping @Sendable (AgentEvent) -> Void
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(budget.runTimeoutMs) / 1000)
        let referencedIds = (request.noticeIds + request.history.flatMap { $0.attachmentIds })
            .uniqued
        var messages: [LlmMessage] = []
        messages.append(.system(try await systemPrompt(referencedIds: referencedIds)))
        messages += request.history
            .filter { $0.role == "user" || $0.role == "assistant" }
            .map { LlmMessage(role: $0.role, content: $0.content) }
        var userContent = PromptTemplates.userQuery(request)
        if !referencedIds.isEmpty {
            // iOS 增强：引用锚点写进 user prompt（注意力最高处）。
            // 用户实测（思考型小模型）：模型会忽略 system 末尾引用块/复述标题链接/
            // 抄错 64 位 id 导致 read_notice 失败——锚点显式区分当前与历史引用并给出行为要求。
            let currentCount = request.noticeIds.count
            let historyCount = referencedIds.count - currentCount
            var note = "（提示：系统提示的「引用的资讯」部分含这些资讯的正文节选。"
            if currentCount > 0 {
                note += "本条消息引用了 \(currentCount) 条资讯，请直接基于其正文回答本条问题；"
            }
            if historyCount > 0 {
                note += "另有 \(historyCount) 条是本会话早前引用过的历史资讯，仅在相关时提及；"
            }
            note += "请给出正文内容的实质总结，不要只复述标题和链接；如需完整正文可调用 read_notice，"
            note += "其 id 参数必须从「引用的资讯」块中完整精确复制。）"
            userContent += "\n\n" + note
        }
        messages.append(.user(userContent))

        var rounds = 0
        var toolCalls = 0
        var totalBytes = 0

        while rounds < budget.maxModelRounds {
            guard Date() < deadline else { throw AgentRunTimeoutError() }
            rounds += 1
            let round = try await collectRound(messages, useTools: true, onText: nil)

            if round.calls.isEmpty {
                // 工具轮的正文不公开：统一再发一次「禁用工具」的流式请求产出最终答案
                if !round.content.trimmingCharacters(in: .whitespaces).isEmpty {
                    messages.append(.assistant(round.content))
                }
                try await finalize(&messages, instruction: PromptTemplates.finalInstruction(), emit: emit)
                emit(.runCompleted(runId: runId))
                return
            }

            messages.append(LlmMessage(role: "assistant", content: round.content, toolCalls: round.calls))

            if round.calls.count > budget.maxToolsPerRound {
                Self.appendSkippedObservations(&messages, calls: round.calls, reason: Self.reasonRoundLimit)
                try await finalize(&messages, instruction: PromptTemplates.limitInstruction(Self.reasonRoundLimit), emit: emit)
                emit(.runCompleted(runId: runId))
                return
            }

            for (index, call) in round.calls.enumerated() {
                if toolCalls >= budget.maxToolCalls {
                    Self.appendSkippedObservations(&messages, calls: Array(round.calls.dropFirst(index)), reason: Self.reasonToolLimit)
                    try await finalize(&messages, instruction: PromptTemplates.limitInstruction(Self.reasonToolLimit), emit: emit)
                    emit(.runCompleted(runId: runId))
                    return
                }
                toolCalls += 1
                totalBytes += try await observe(call, index: toolCalls, messages: &messages, emit: emit)
                if totalBytes > budget.maxTotalToolBytes {
                    Self.appendSkippedObservations(&messages, calls: Array(round.calls.dropFirst(index + 1)), reason: Self.reasonOutputLimit)
                    try await finalize(&messages, instruction: PromptTemplates.limitInstruction(Self.reasonOutputLimit), emit: emit)
                    emit(.runCompleted(runId: runId))
                    return
                }
            }
        }

        try await finalize(&messages, instruction: PromptTemplates.limitInstruction(Self.reasonRoundLimit), emit: emit)
        emit(.runCompleted(runId: runId))
    }

    /// 执行一次工具调用，发送配对事件，并把截断后的观察写入 messages。
    private func observe(
        _ call: LlmToolCall,
        index: Int,
        messages: inout [LlmMessage],
        emit: @escaping @Sendable (AgentEvent) -> Void
    ) async throws -> Int {
        let toolId = "tool-\(index)"
        let summary = tools.supports(call.name)
            ? await tools.summarize(call.name, call.arguments)
            : "未知工具"
        emit(.toolStarted(
            toolId: toolId, name: call.name, summary: summary,
            targetId: tools.targetId(call.name, call.arguments)
        ))

        let started = Date()
        let status: String
        let code: String?
        let output: String
        do {
            output = try await tools.execute(call.name, call.arguments)
            status = AgentEvent.statusCompleted
            code = nil
        } catch let error as AgentToolException {
            status = AgentEvent.statusFailed
            code = error.code
            output = "工具执行失败（\(error.code)）：\(error.message)"
        } catch {
            status = AgentEvent.statusFailed
            code = "tool_failed"
            output = "工具执行失败：\(error.localizedDescription)"
        }

        emit(.toolCompleted(
            toolId: toolId, name: call.name, status: status,
            durationMs: Int64(Date().timeIntervalSince(started) * 1000), code: code
        ))

        let clipped = Self.clipUtf8(output, limit: budget.maxToolResultBytes)
        messages.append(.tool(callId: call.id, clipped))
        return clipped.utf8.count
    }

    /// 收束：追加指令后做一次禁用工具的流式请求。
    private func finalize(
        _ messages: inout [LlmMessage],
        instruction: String,
        emit: @escaping @Sendable (AgentEvent) -> Void
    ) async throws {
        messages.append(.user(instruction))
        let streamed = FlagBox()
        let round = try await collectRound(messages, useTools: false, onText: { text in
            streamed.set()
            emit(.answerDelta(text: text, delivery: AgentEvent.deliveryStreaming))
        })
        if !streamed.value && !round.content.trimmingCharacters(in: .whitespaces).isEmpty {
            emit(.answerDelta(text: round.content, delivery: AgentEvent.deliveryBuffered))
        }
    }

    private struct ModelRound {
        var content: String
        var calls: [LlmToolCall]
    }

    /// 完成一次模型请求，累积正文与跨帧的 tool_calls 增量。
    private func collectRound(
        _ messages: [LlmMessage],
        useTools: Bool,
        onText: (@Sendable (String) -> Void)?
    ) async throws -> ModelRound {
        let acc = RoundAccumulator()
        try await withTimeout(milliseconds: budget.modelTimeoutMs) {
            let specs = useTools
                ? self.tools.specs.map { LlmToolSpec(name: $0.name, description: $0.description, parametersJson: $0.parameters) }
                : []
            let stream = self.client.streamChat(messages: messages, tools: specs)
            for try await delta in stream {
                switch delta {
                case .text(let value):
                    acc.appendContent(value)
                    onText?(value)
                case .toolCallDelta(let index, let id, let name, let argumentsChunk):
                    acc.appendCallDelta(index: index, id: id, name: name, argumentsChunk: argumentsChunk)
                case .finished:
                    break
                }
            }
        }

        var calls: [LlmToolCall] = []
        for index in acc.callIndexes.sorted() {
            calls.append(LlmToolCall(
                id: acc.id(index) ?? "call_\(index)",
                name: acc.name(index) ?? "",
                arguments: acc.arguments(index) ?? "{}"
            ))
        }
        return ModelRound(content: acc.content, calls: calls)
    }

    private func systemPrompt(referencedIds: [String]) async throws -> String {
        let catalog = (try? await repository.corpusCatalog()) ?? CorpusCatalog(total: 0, firstDay: nil, lastDay: nil)
        let sources = (try? await repository.subscribedSources()) ?? []
        let lastCrawl = sources.compactMap { $0.lastRunAt }.max()
        var base = PromptTemplates.systemPrompt + "\n" + PromptTemplates.toolInstructions + "\n"
            + PromptTemplates.metadata(
                catalog: catalog, lastCrawlMillis: lastCrawl,
                now: Date(), timeZone: timeZone,
                sources: sources.map { ($0.id, $0.name) }
            )
        if let referenced = try await referencedNoticeBlock(ids: referencedIds, sources: sources) {
            base += "\n" + referenced
        }
        return base
    }

    /// 把本会话引用过的资讯（当前 + 历史，去重）汇总成一段 system 文本。
    private func referencedNoticeBlock(ids: [String], sources: [NoticeSourceRecord]) async throws -> String? {
        if ids.isEmpty { return nil }
        let names = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.name) })
        var sb = ""
        var used = 0
        for id in ids.prefix(Self.maxReferencedNotices) {
            let notice = (try? await repository.findNotice(id: id)) ?? nil
            let head: String
            if let notice {
                var line = "- \(notice.title)（\(notice.publishedDay)"
                if let sourceId = notice.sourceId, let name = names[sourceId], !name.isEmpty {
                    line += "，\(name)"
                }
                line += "，id=\(notice.id)）"
                head = line
            } else {
                head = "- id=\(id)（本地未找到）"
            }
            let excerpt = String((notice?.content ?? "").trimmingCharacters(in: .whitespaces).prefix(Self.referencedExcerptChars))
            let block = excerpt.isEmpty ? head : head + "\n" + excerpt
            if used + block.count > Self.maxReferencedChars { break }
            sb += "\n\n" + block
            used += block.count
        }
        if sb.isEmpty { return nil }
        return "【引用的资讯】用户在本会话中引用了以下资讯（含正文节选），回答时应优先依据这些内容；"
            + "需要完整正文再用 read_notice(id)：" + sb
    }

    private func withTimeout<T: Sendable>(milliseconds: Int, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                throw AgentRunTimeoutError()
            }
            guard let first = try await group.next() else {
                throw AgentRunTimeoutError()
            }
            group.cancelAll()
            return first
        }
    }

    private static func appendSkippedObservations(
        _ messages: inout [LlmMessage],
        calls: [LlmToolCall],
        reason: String
    ) {
        for call in calls {
            messages.append(.tool(callId: call.id, "该工具调用未执行：检索因 \(reason) 停止。"))
        }
    }

    // MARK: - 常量与工具函数

    static let reasonRoundLimit = "round_limit"
    static let reasonToolLimit = "tool_limit"
    static let reasonOutputLimit = "tool_output_limit"

    private static let maxReferencedNotices = 5
    private static let referencedExcerptChars = 1_500
    private static let maxReferencedChars = 6_000

    /// 按 UTF-8 字节截断，不破坏字符编码。
    static func clipUtf8(_ text: String, limit: Int) -> String {
        let bytes = Array(text.utf8)
        if bytes.count <= limit { return text }
        if limit <= Self.truncatedSuffix.utf8.count {
            return String(Self.truncatedSuffix.prefix(limit))
        }
        var cut = limit - Self.truncatedSuffix.utf8.count
        while cut > 0 && (bytes[cut] & 0xC0) == 0x80 {
            cut -= 1
        }
        return String(decoding: bytes[0..<cut], as: UTF8.self) + Self.truncatedSuffix
    }
}

private extension Array where Element == String {
    var uniqued: [String] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// @Sendable 闭包内顺序累积的容器（单 task 顺序消费，无需锁）。
final class RoundAccumulator: @unchecked Sendable {
    private(set) var content = ""
    private var ids: [Int: String] = [:]
    private var names: [Int: String] = [:]
    private var args: [Int: String] = [:]

    func appendContent(_ value: String) { content += value }

    func appendCallDelta(index: Int, id: String?, name: String?, argumentsChunk: String?) {
        if let id { ids[index, default: ""].append(id) }
        if let name { names[index, default: ""].append(name) }
        if let argumentsChunk { args[index, default: ""].append(argumentsChunk) }
    }

    var callIndexes: [Int] { Array(Set(ids.keys).union(names.keys).union(args.keys)) }
    func id(_ index: Int) -> String? { ids[index].flatMap { $0.isEmpty ? nil : $0 } }
    func name(_ index: Int) -> String? { names[index].flatMap { $0.isEmpty ? nil : $0 } }
    func arguments(_ index: Int) -> String? { args[index].flatMap { $0.isEmpty ? nil : $0 } }
}

final class FlagBox: @unchecked Sendable {
    private(set) var value = false
    func set() { value = true }
}
