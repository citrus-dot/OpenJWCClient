import Foundation
import GRDB

/// 聊天枚举：String 存库，解码失败回退默认值（对齐 Android Converters 的 try-catch）。
enum ChatRole: String, Codable, DatabaseValueConvertible {
    case user = "USER"
    case assistant = "ASSISTANT"

    static func from(databaseValue: DatabaseValue) -> Self? {
        guard let raw = databaseValue.storage.value as? String else { return nil }
        return ChatRole(rawValue: raw) ?? .user
    }
}

enum ChatMessageStatus: String, Codable, DatabaseValueConvertible {
    case running = "RUNNING"
    case completed = "COMPLETED"
    case failed = "FAILED"

    static func from(databaseValue: DatabaseValue) -> Self? {
        guard let raw = databaseValue.storage.value as? String else { return nil }
        return ChatMessageStatus(rawValue: raw) ?? .completed
    }
}

// MARK: - chat_metadata

struct ChatSessionRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "chat_metadata"

    var sessionId: Int64?
    var title: String
    var lastUpdated: Int64
}

// MARK: - chat_messages

struct ChatMessageRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "chat_messages"

    var messageId: Int64?
    var ownerSessionId: Int64
    var text: String
    var role: ChatRole
    var attachmentTitles: JSONStringList
    var attachmentIds: JSONStringList
    var status: ChatMessageStatus
    var runId: String?
    var delivery: String?
    var errorCode: String?
    var timestamp: Int64
}

// MARK: - chat_tool_calls

struct ChatToolCallRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "chat_tool_calls"

    var id: Int64?
    var messageId: Int64
    var position: Int
    var name: String
    var summary: String
    var status: String
    var code: String?
    var durationMs: Int64?
    var targetId: String?
}

// MARK: - 聚合（对齐 Android ChatSession / ChatTurn，手写组装）

struct ChatSession: Equatable {
    var metadata: ChatSessionRecord
    var messages: [ChatMessageRecord]
}

struct ChatTurn: Equatable {
    var message: ChatMessageRecord
    var toolCalls: [ChatToolCallRecord]
}
