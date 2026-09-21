import Foundation
import GRDB

/// 聊天三层持久化 DAO。SQL 逐条对照 Android `ChatDao`；
/// 消息排序在 Android `timestamp ASC` 基础上补 `messageId ASC` tie-break（同毫秒按插入序，无损增强）。
struct ChatDao: Sendable {
    let db: any DatabaseWriter

    /* ================= 会话 ================= */

    func allSessions() async throws -> [ChatSession] {
        try await db.read { db in
            let metas = try ChatSessionRecord.fetchAll(
                db, sql: "SELECT * FROM chat_metadata ORDER BY lastUpdated DESC"
            )
            return metas.map { meta in
                let messages = (try? ChatMessageRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM chat_messages WHERE ownerSessionId = ? ORDER BY timestamp ASC, messageId ASC",
                    arguments: [meta.sessionId]
                )) ?? []
                return ChatSession(metadata: meta, messages: messages)
            }
        }
    }

    func sessionById(id: Int64) async throws -> ChatSession? {
        try await db.read { db in
            guard let meta = try ChatSessionRecord.fetchOne(
                db, sql: "SELECT * FROM chat_metadata WHERE sessionId = ?", arguments: [id]
            ) else { return nil }
            let messages = try ChatMessageRecord.fetchAll(
                db,
                sql: "SELECT * FROM chat_messages WHERE ownerSessionId = ? ORDER BY timestamp ASC, messageId ASC",
                arguments: [id]
            )
            return ChatSession(metadata: meta, messages: messages)
        }
    }

    @discardableResult
    func insertMetadata(_ metadata: ChatSessionRecord) async throws -> Int64 {
        try await db.write { db in
            try metadata.insert(db)
            return db.lastInsertedRowID
        }
    }

    func updateMetadata(_ metadata: ChatSessionRecord) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE chat_metadata SET title = ?, lastUpdated = ? WHERE sessionId = ?",
                arguments: [metadata.title, metadata.lastUpdated, metadata.sessionId]
            )
        }
    }

    func updateLastUpdated(sessionId: Int64, timestamp: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE chat_metadata SET lastUpdated = ? WHERE sessionId = ?",
                arguments: [timestamp, sessionId]
            )
        }
    }

    func deleteSession(sessionId: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM chat_metadata WHERE sessionId = ?", arguments: [sessionId])
        }
    }

    func deleteAllSessions() async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM chat_metadata")
        }
    }

    /* ================= 消息 ================= */

    @discardableResult
    func insertMessage(_ message: ChatMessageRecord) async throws -> Int64 {
        try await db.write { db in
            try message.insert(db)
            return db.lastInsertedRowID
        }
    }

    func updateMessageText(messageId: Int64, newText: String) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE chat_messages SET text = ? WHERE messageId = ?",
                arguments: [newText, messageId]
            )
        }
    }

    func updateMessageRunId(messageId: Int64, runId: String) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE chat_messages SET runId = ? WHERE messageId = ?",
                arguments: [runId, messageId]
            )
        }
    }

    /// 结束一轮回答：写入正文、状态、交付方式与失败 code。
    func finishMessage(messageId: Int64, text: String, status: ChatMessageStatus, delivery: String?, errorCode: String?) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: """
                UPDATE chat_messages SET text = ?, status = ?, delivery = ?, errorCode = ? \
                WHERE messageId = ?
                """,
                arguments: [text, status, delivery, errorCode, messageId]
            )
        }
    }

    func messages(sessionId: Int64) async throws -> [ChatMessageRecord] {
        try await db.read { db in
            try ChatMessageRecord.fetchAll(
                db,
                sql: "SELECT * FROM chat_messages WHERE ownerSessionId = ? ORDER BY timestamp ASC, messageId ASC",
                arguments: [sessionId]
            )
        }
    }

    func deleteMessageById(messageId: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM chat_messages WHERE messageId = ?", arguments: [messageId])
        }
    }

    /* ================= 工具轨迹 ================= */

    @discardableResult
    func insertToolCall(_ call: ChatToolCallRecord) async throws -> Int64 {
        try await db.write { db in
            try call.insert(db)
            return db.lastInsertedRowID
        }
    }

    func completeToolCall(id: Int64, status: String, code: String?, durationMs: Int64?) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE chat_tool_calls SET status = ?, code = ?, durationMs = ? WHERE id = ?",
                arguments: [status, code, durationMs, id]
            )
        }
    }

    func toolCalls(messageId: Int64) async throws -> [ChatToolCallRecord] {
        try await db.read { db in
            try ChatToolCallRecord.fetchAll(
                db,
                sql: "SELECT * FROM chat_tool_calls WHERE messageId = ? ORDER BY position ASC",
                arguments: [messageId]
            )
        }
    }

    func toolCallsBySession(sessionId: Int64) async throws -> [ChatToolCallRecord] {
        try await db.read { db in
            try ChatToolCallRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM chat_tool_calls WHERE messageId IN \
                (SELECT messageId FROM chat_messages WHERE ownerSessionId = ?) \
                ORDER BY messageId ASC, position ASC
                """,
                arguments: [sessionId]
            )
        }
    }

    /// 会话内全部消息及其工具轨迹（对齐 Android `@Transaction` + `@Relation` 的 ChatTurn 组装）。
    func turns(sessionId: Int64) async throws -> [ChatTurn] {
        let messages = try await messages(sessionId: sessionId)
        let calls = try await toolCallsBySession(sessionId: sessionId)
        var grouped: [Int64: [ChatToolCallRecord]] = [:]
        for call in calls {
            grouped[call.messageId, default: []].append(call)
        }
        return messages.map { ChatTurn(message: $0, toolCalls: grouped[$0.messageId ?? -1] ?? []) }
    }
}
