import Foundation

// MARK: - 模型层（对齐 Android net/llm/LlmModels.kt）

/// LLM 供应商协议。绝大多数厂商兼容 OPENAI 的 `/chat/completions`。
public enum LlmProtocol: String, Codable, Sendable {
    case OPENAI, ANTHROPIC, GEMINI
}

/// 供应商无关的对话消息。
public struct LlmMessage: Sendable, Equatable {
    public var role: String
    public var content: String
    public var toolCallId: String?
    public var toolCalls: [LlmToolCall]?

    public init(role: String, content: String = "", toolCallId: String? = nil, toolCalls: [LlmToolCall]? = nil) {
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
    }

    public static func system(_ text: String) -> LlmMessage { LlmMessage(role: "system", content: text) }
    public static func user(_ text: String) -> LlmMessage { LlmMessage(role: "user", content: text) }
    public static func assistant(_ text: String) -> LlmMessage { LlmMessage(role: "assistant", content: text) }
    public static func tool(callId: String, _ text: String) -> LlmMessage {
        LlmMessage(role: "tool", content: text, toolCallId: callId)
    }
}

/// 模型请求的一次工具调用。
public struct LlmToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String = "", name: String = "", arguments: String = "") {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// 提供给模型的工具描述。parametersJson 是 JSON Schema 字符串。
public struct LlmToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parametersJson: String

    public init(name: String, description: String, parametersJson: String) {
        self.name = name
        self.description = description
        self.parametersJson = parametersJson
    }
}

/// 流式增量。
public enum LlmDelta: Sendable {
    case text(String)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsChunk: String?)
    case finished(String?)
}

/// LLM HTTP 层错误。
public struct LlmHttpException: Error, CustomStringConvertible {
    public let status: Int
    public let responseText: String
    public var description: String { "LLM HTTP \(status)" }

    public init(status: Int, responseText: String) {
        self.status = status
        self.responseText = responseText
    }
}

/// 配置不完整（缺少 Key / baseUrl / model）。
public struct LlmConfigException: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    public init(_ message: String) { self.message = message }
}

// MARK: - 客户端协议

/// 供应商无关的流式聊天客户端。
public protocol LlmClient: Sendable {
    var config: LlmProviderConfig { get }
    func streamChat(messages: [LlmMessage], tools: [LlmToolSpec]) -> AsyncThrowingStream<LlmDelta, Error>
}

// MARK: - 供应商预设

/// 供应商预设，用于设置页一键填充。
public struct LlmPreset: Sendable {
    public let id: String
    public let name: String
    public let baseUrl: String
    public let defaultModel: String
    public let `protocol`: LlmProtocol

    public init(id: String, name: String, baseUrl: String, defaultModel: String, protocol: LlmProtocol = .OPENAI) {
        self.id = id
        self.name = name
        self.baseUrl = baseUrl
        self.defaultModel = defaultModel
        self.`protocol` = `protocol`
    }
}

public enum LlmPresets {
    public static let all: [LlmPreset] = [
        LlmPreset(id: "openai", name: "OpenAI", baseUrl: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini"),
        LlmPreset(id: "deepseek", name: "DeepSeek", baseUrl: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat"),
        LlmPreset(id: "moonshot", name: "Moonshot / Kimi", baseUrl: "https://api.moonshot.cn/v1", defaultModel: "moonshot-v1-8k"),
        LlmPreset(id: "zhipu", name: "智谱 GLM", baseUrl: "https://open.bigmodel.cn/api/paas/v4", defaultModel: "glm-4-flash"),
        LlmPreset(id: "qwen", name: "阿里百炼 Qwen", baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1", defaultModel: "qwen-plus"),
        LlmPreset(id: "openrouter", name: "OpenRouter", baseUrl: "https://openrouter.ai/api/v1", defaultModel: "openai/gpt-4o-mini"),
        LlmPreset(id: "siliconflow", name: "SiliconFlow", baseUrl: "https://api.siliconflow.cn/v1", defaultModel: "Qwen/Qwen2.5-7B-Instruct"),
        LlmPreset(id: "groq", name: "Groq", baseUrl: "https://api.groq.com/openai/v1", defaultModel: "llama-3.3-70b-versatile"),
        LlmPreset(id: "ollama", name: "Ollama（局域网/本地）", baseUrl: "http://192.168.1.2:11434/v1", defaultModel: "qwen2.5"),
        LlmPreset(id: "custom", name: "自定义", baseUrl: "", defaultModel: ""),
    ]

    public static func byId(_ id: String) -> LlmPreset {
        all.first { $0.id == id } ?? all[all.count - 1]
    }

    public static func matchId(_ baseUrl: String) -> String {
        all.first { !$0.baseUrl.isEmpty && $0.baseUrl == baseUrl }?.id ?? "custom"
    }
}

// MARK: - OpenAI 兼容流式客户端

/// 兼容 OpenAI `/chat/completions` 的流式客户端（URLSession SSE）。
/// 覆盖 OpenAI / DeepSeek / Moonshot / GLM / Qwen(DashScope) / OpenRouter / Groq / Ollama 等。
public struct OpenAiCompatibleClient: LlmClient {
    public let config: LlmProviderConfig
    private let apiKey: String
    private let session: URLSession

    public init(config: LlmProviderConfig, apiKey: String, session: URLSession = .shared) {
        self.config = config
        self.apiKey = apiKey
        self.session = session
    }

    private static func buildPayload(messages: [LlmMessage], tools: [LlmToolSpec], config: LlmProviderConfig) throws -> Data {
        var messageObjects: [[String: Any]] = []
        for message in messages {
            var obj: [String: Any] = ["role": message.role]
            if let toolCallId = message.toolCallId {
                obj["tool_call_id"] = toolCallId
            }
            if let calls = message.toolCalls, !calls.isEmpty {
                obj["tool_calls"] = calls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.name, "arguments": call.arguments],
                    ] as [String: Any]
                }
            } else {
                obj["content"] = message.content
            }
            messageObjects.append(obj)
        }

        var payload: [String: Any] = [
            "model": config.model,
            "stream": true,
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "messages": messageObjects,
        ]
        if !tools.isEmpty {
            payload["tools"] = tools.map { tool in
                let parameters = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJson.utf8)))
                    ?? ["type": "object"]
                return [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": parameters,
                    ],
                ] as [String: Any]
            }
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    public func streamChat(messages: [LlmMessage], tools: [LlmToolSpec]) -> AsyncThrowingStream<LlmDelta, Error> {
        if apiKey.isEmpty {
            return AsyncThrowingStream { $0.finish(throwing: LlmConfigException("缺少 API Key")) }
        }
        if config.baseUrl.isEmpty || config.model.isEmpty {
            return AsyncThrowingStream { $0.finish(throwing: LlmConfigException("缺少 baseUrl 或 model")) }
        }

        let url = config.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
        let payload: Data
        do {
            payload = try Self.buildPayload(messages: messages, tools: tools, config: config)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        var mutableRequest = URLRequest(url: URL(string: url)!)
        mutableRequest.httpMethod = "POST"
        mutableRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        mutableRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        mutableRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        mutableRequest.httpBody = payload
        let request = mutableRequest

        let session = self.session
        return AsyncThrowingStream(LlmDelta.self) { continuation in
            let task = Task {
                await Self.pumpSSE(session: session, request: request, into: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// SSE 主循环（Sendable 静态，规避 Task 闭包捕获检查）。
    private static func pumpSSE(
        session: URLSession,
        request: URLRequest,
        into continuation: AsyncThrowingStream<LlmDelta, Error>.Continuation
    ) async {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LlmHttpException(status: -1, responseText: "无 HTTP 响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                var text = ""
                for try await line in bytes.lines {
                    text += line + "\n"
                    if text.count > 4096 { break }
                }
                throw LlmHttpException(status: http.statusCode, responseText: text)
            }
            var finished = false
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                if line.isEmpty || line.hasPrefix(":") { continue }
                guard line.hasPrefix("data:") else { continue }
                let data = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if data.isEmpty { continue }
                if data == "[DONE]" {
                    finished = true
                    break
                }
                for delta in parseChunk(data) {
                    if delta.isFinished { finished = true }
                    continuation.yield(delta)
                }
            }
            if !finished {
                continuation.yield(.finished(nil))
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// 解析一个 SSE data 帧（对齐 Android parseChunk）。
    static func parseChunk(_ data: String) -> [LlmDelta] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let choice = choices.first else {
            return []
        }
        var deltas: [LlmDelta] = []

        if let delta = choice["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                deltas.append(.text(content))
            }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let index = (call["index"] as? Int) ?? 0
                    let function = call["function"] as? [String: Any]
                    deltas.append(.toolCallDelta(
                        index: index,
                        id: call["id"] as? String,
                        name: function?["name"] as? String,
                        argumentsChunk: function?["arguments"] as? String
                    ))
                }
            }
        }

        if let finishReason = choice["finish_reason"] as? String,
           !finishReason.isEmpty, finishReason != "null" {
            deltas.append(.finished(finishReason))
        }
        return deltas
    }
}

extension LlmDelta {
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}
