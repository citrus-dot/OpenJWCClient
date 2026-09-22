import Foundation

// MARK: - Agent 类型（对齐 Android agent/AgentModels.kt + AgentBudget.kt）

/// 提供给模型的工具描述。parameters 是 JSON Schema 字符串。
public struct AgentToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: String

    public init(name: String, description: String, parameters: String) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// 一次 Agent 运行的输入。
public struct AgentRequest: Sendable {
    /// 用户问题，或日报这类批量任务的任务描述。
    public var query: String
    /// 只允许 user / assistant 的已完成历史。
    public var history: [AgentMessage]
    /// 用户显式选中的资讯，会作为证据提示拼进问题。
    public var noticeIds: [String]

    public init(query: String, history: [AgentMessage] = [], noticeIds: [String] = []) {
        self.query = query
        self.history = history
        self.noticeIds = noticeIds
    }
}

/// 对话消息（工具轮会带 toolCalls，工具结果带 toolCallId）。
public struct AgentMessage: Sendable, Equatable {
    public var role: String
    public var content: String
    public var toolCalls: [LlmToolCall]
    public var toolCallId: String?
    /// 该条用户消息引用过的资讯 id。
    public var attachmentIds: [String]

    public init(
        role: String, content: String = "", toolCalls: [LlmToolCall] = [],
        toolCallId: String? = nil, attachmentIds: [String] = []
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.attachmentIds = attachmentIds
    }

    public static func user(_ text: String) -> AgentMessage { AgentMessage(role: "user", content: text) }
    public static func assistant(_ text: String) -> AgentMessage { AgentMessage(role: "assistant", content: text) }
}

/// 运行期间对外产出的事件；语义与后端 Chat v2 对齐。
public enum AgentEvent: Sendable {
    case runStarted(runId: String)
    case toolStarted(toolId: String, name: String, summary: String, targetId: String?)
    case toolCompleted(toolId: String, name: String, status: String, durationMs: Int64, code: String?)
    case answerDelta(text: String, delivery: String)
    case runCompleted(runId: String)
    case runFailed(runId: String, code: String, summary: String)

    public static let deliveryStreaming = "streaming-final"
    public static let deliveryBuffered = "buffered-final"
    public static let statusCompleted = "completed"
    public static let statusFailed = "failed"
}

/// 运行失败分类，用于给出稳定 code 与安全摘要。
public enum AgentFailure: String, CaseIterable, Sendable {
    case timeout = "agent_timeout"
    case modelUnavailable = "model_unavailable"
    case modelAuth = "agent_auth_error"
    case modelNotFound = "agent_model_not_found"
    case modelRateLimited = "agent_rate_limited"
    case modelProtocol = "model_protocol_error"
    case configuration = "agent_configuration_error"
    case cancelled = "agent_cancelled"
    case failed = "agent_failed"

    public var summary: String {
        switch self {
        case .timeout: return "问答超时，请重试或缩小问题范围"
        case .modelUnavailable: return "模型服务暂不可用，请稍后重试"
        case .modelAuth: return "API Key 无效或没有权限，请到「AI 模型设置」检查"
        case .modelNotFound: return "模型名称或接口地址不正确，请到「AI 模型设置」检查"
        case .modelRateLimited: return "请求过于频繁或额度不足，请稍后重试"
        case .modelProtocol: return "模型响应异常，请重试"
        case .configuration: return "尚未配置可用的模型，请先在设置中填写"
        case .cancelled: return "问答已取消"
        case .failed: return "问答未完成，请重试"
        }
    }

    /// 需要用户去「AI 模型设置」修正的失败（聊天页会直接跳过去）。
    public static let configRelated: Set<String> = [
        AgentFailure.configuration.rawValue,
        AgentFailure.modelAuth.rawValue,
        AgentFailure.modelNotFound.rawValue,
    ]

    /// 按 HTTP 状态码归类。
    public static func fromHttpStatus(_ status: Int) -> AgentFailure {
        switch status {
        case 401, 403: return .modelAuth
        case 404: return .modelNotFound
        case 429: return .modelRateLimited
        default: return .modelUnavailable
        }
    }
}

/// 单次 Agent 运行的资源上限。默认值对齐后端 `agent_*` 系统设置，硬编码不可被远端覆盖。
public struct AgentBudget: Sendable {
    public var maxModelRounds: Int
    public var maxToolCalls: Int
    public var maxToolsPerRound: Int
    /// 单次工具结果字符上限（按 UTF-8 字节计）。
    public var maxToolResultBytes: Int
    /// 累计工具结果上限。
    public var maxTotalToolBytes: Int
    public var modelTimeoutMs: Int
    public var runTimeoutMs: Int

    public init(
        maxModelRounds: Int = 8,
        maxToolCalls: Int = 16,
        maxToolsPerRound: Int = 4,
        maxToolResultBytes: Int = 16_000,
        maxTotalToolBytes: Int = 96_000,
        modelTimeoutMs: Int = 45_000,
        runTimeoutMs: Int = 120_000
    ) {
        precondition(maxTotalToolBytes >= maxToolResultBytes, "累计工具结果预算不得低于单次上限")
        precondition(runTimeoutMs >= modelTimeoutMs, "总超时不得低于模型超时")
        self.maxModelRounds = maxModelRounds
        self.maxToolCalls = maxToolCalls
        self.maxToolsPerRound = maxToolsPerRound
        self.maxToolResultBytes = maxToolResultBytes
        self.maxTotalToolBytes = maxTotalToolBytes
        self.modelTimeoutMs = modelTimeoutMs
        self.runTimeoutMs = runTimeoutMs
    }
}

/// 工具执行失败（会作为失败观察交给模型继续检索，不等于整轮失败）。
public struct AgentToolException: Error {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// Agent 以失败终止（携带稳定 code 与安全摘要）。
public struct AgentRunFailedException: Error {
    public let code: String
    public let summary: String

    public init(code: String, summary: String) {
        self.code = code
        self.summary = summary
    }
}

/// 整轮运行超出预算。
public struct AgentRunTimeoutError: Error {}
