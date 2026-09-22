import Foundation
import GRDB

/// 聊天枚举：String 存库，解码失败回退默认值（对齐 Android Converters 的 try-catch）。
public enum ChatRole: String, Codable, DatabaseValueConvertible, Sendable {
    case user = "USER"
    case assistant = "ASSISTANT"

    public static func from(databaseValue: DatabaseValue) -> Self? {
        guard let raw = databaseValue.storage.value as? String else { return nil }
        return ChatRole(rawValue: raw) ?? .user
    }
}

public enum ChatMessageStatus: String, Codable, DatabaseValueConvertible, Sendable {
    case running = "RUNNING"
    case completed = "COMPLETED"
    case failed = "FAILED"

    public static func from(databaseValue: DatabaseValue) -> Self? {
        guard let raw = databaseValue.storage.value as? String else { return nil }
        return ChatMessageStatus(rawValue: raw) ?? .completed
    }
}

// MARK: - chat_metadata

public struct ChatSessionRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "chat_metadata"

    public var sessionId: Int64?
    public var title: String
    public var lastUpdated: Int64

    public init(sessionId: Int64? = nil, title: String, lastUpdated: Int64) {
        self.sessionId = sessionId
        self.title = title
        self.lastUpdated = lastUpdated
    }
}

// MARK: - chat_messages

public struct ChatMessageRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "chat_messages"

    public var messageId: Int64?
    public var ownerSessionId: Int64
    public var text: String
    public var role: ChatRole
    public var attachmentTitles: JSONStringList
    public var attachmentIds: JSONStringList
    public var status: ChatMessageStatus
    public var runId: String?
    public var delivery: String?
    public var errorCode: String?
    public var timestamp: Int64

    public init(
        messageId: Int64? = nil, ownerSessionId: Int64, text: String, role: ChatRole,
        attachmentTitles: JSONStringList = JSONStringList(),
        attachmentIds: JSONStringList = JSONStringList(),
        status: ChatMessageStatus, runId: String? = nil, delivery: String? = nil,
        errorCode: String? = nil, timestamp: Int64
    ) {
        self.messageId = messageId
        self.ownerSessionId = ownerSessionId
        self.text = text
        self.role = role
        self.attachmentTitles = attachmentTitles
        self.attachmentIds = attachmentIds
        self.status = status
        self.runId = runId
        self.delivery = delivery
        self.errorCode = errorCode
        self.timestamp = timestamp
    }
}

// MARK: - chat_tool_calls

public struct ChatToolCallRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "chat_tool_calls"

    public var id: Int64?
    public var messageId: Int64
    public var position: Int
    public var name: String
    public var summary: String
    public var status: String
    public var code: String?
    public var durationMs: Int64?
    public var targetId: String?

    public init(
        id: Int64? = nil, messageId: Int64, position: Int, name: String, summary: String,
        status: String, code: String? = nil, durationMs: Int64? = nil, targetId: String? = nil
    ) {
        self.id = id
        self.messageId = messageId
        self.position = position
        self.name = name
        self.summary = summary
        self.status = status
        self.code = code
        self.durationMs = durationMs
        self.targetId = targetId
    }
}

// MARK: - 聚合（对齐 Android ChatSession / ChatTurn，手写组装）

public struct ChatSession: Equatable, Sendable {
    public var metadata: ChatSessionRecord
    public var messages: [ChatMessageRecord]

    public init(metadata: ChatSessionRecord, messages: [ChatMessageRecord]) {
        self.metadata = metadata
        self.messages = messages
    }
}

public struct ChatTurn: Equatable, Sendable {
    public var message: ChatMessageRecord
    public var toolCalls: [ChatToolCallRecord]

    public init(message: ChatMessageRecord, toolCalls: [ChatToolCallRecord]) {
        self.message = message
        self.toolCalls = toolCalls
    }
}
