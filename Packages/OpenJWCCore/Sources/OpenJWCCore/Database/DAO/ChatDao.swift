import Foundation
import GRDB

/// 聊天三层持久化 DAO。SQL 逐条对照 Android `ChatDao`；
/// 消息排序在 Android `timestamp ASC` 基础上补 `messageId ASC` tie-break（同毫秒按插入序，无损增强）。
public struct ChatDao: Sendable {
    let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    /* ================= ValueObservation 静态查询（同步 read 上下文） ================= */

    /// 会话列表（倒序；观察闭包用）。
    public static func allSessionsSync(_ db: Database) throws -> [ChatSessionRecord] {
        try ChatSessionRecord.fetchAll(
            db, sql: "SELECT * FROM chat_metadata ORDER BY lastUpdated DESC"
        )
    }

    /// 会话内全部消息 + 工具轨迹组装（messages + tool_calls 双表读取，
    /// GRDB 自动观察两张表的读取区域，任一表写入即重发）。
    public static func turnsSync(_ db: Database, sessionId: Int64) throws -> [ChatTurn] {
        let messages = try ChatMessageRecord.fetchAll(
            db,
            sql: "SELECT * FROM chat_messages WHERE ownerSessionId = ? ORDER BY timestamp ASC, messageId ASC",
            arguments: [sessionId]
        )
        let calls = try ChatToolCallRecord.fetchAll(
            db,
            sql: """
            SELECT * FROM chat_tool_calls WHERE messageId IN \
            (SELECT messageId FROM chat_messages WHERE ownerSessionId = ?) \
            ORDER BY messageId ASC, position ASC
            """,
            arguments: [sessionId]
        )
        var grouped: [Int64: [ChatToolCallRecord]] = [:]
        for call in calls {
            grouped[call.messageId, default: []].append(call)
        }
        return messages.map { ChatTurn(message: $0, toolCalls: grouped[$0.messageId ?? -1] ?? []) }
    }

    /* ================= 会话 ================= */

    public func allSessions() async throws -> [ChatSession] {
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

    public func sessionById(id: Int64) async throws -> ChatSession? {
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
    public func insertMetadata(_ metadata: ChatSessionRecord) async throws -> Int64 {
        try await db.write { db in
            try metadata.insert(db)
            return db.lastInsertedRowID
        }
    }

    public func updateMetadata(_ metadata: ChatSessionRecord) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE chat_metadata SET title = ?, lastUpdated = ? WHERE sessionId = ?",
                arguments: [metadata.title, metadata.lastUpdated, metadata.sessionId]
            )
        }
    }

    public func updateLastUpdated(sessionId: Int64, timestamp: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE chat_metadata SET lastUpdated = ? WHERE sessionId = ?",
                arguments: [timestamp, sessionId]
            )
        }
    }

    public func deleteSession(sessionId: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM chat_metadata WHERE sessionId = ?", arguments: [sessionId])
        }
    }

    public func deleteAllSessions() async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM chat_metadata")
        }
    }

    /* ================= 消息 ================= */

    @discardableResult
    public func insertMessage(_ message: ChatMessageRecord) async throws -> Int64 {
        try await db.write { db in
            try message.insert(db)
            return db.lastInsertedRowID
        }
    }

    public func updateMessageText(messageId: Int64, newText: String) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE chat_messages SET text = ? WHERE messageId = ?",
                arguments: [newText, messageId]
            )
        }
    }

    public func updateMessageRunId(messageId: Int64, runId: String) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE chat_messages SET runId = ? WHERE messageId = ?",
                arguments: [runId, messageId]
            )
        }
    }

    /// 结束一轮回答：写入正文、状态、交付方式与失败 code。
    public func finishMessage(messageId: Int64, text: String, status: ChatMessageStatus, delivery: String?, errorCode: String?) async throws {
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

    /// 把会话内全部 RUNNING 占位收敛为 FAILED（用户停止/进程中断的兜底；对齐 spec 停止落库语义）。
    /// 返回被收敛的行数。
    @discardableResult
    public func finishRunningMessages(sessionId: Int64, text: String, errorCode: String) async throws -> Int {
        let assistantRaw = ChatRole.assistant.rawValue
        let runningRaw = ChatMessageStatus.running.rawValue
        let failedRaw = ChatMessageStatus.failed.rawValue
        let sql = "UPDATE chat_messages SET text = ?, status = ?, errorCode = ? WHERE ownerSessionId = ? AND role = ? AND status = ?"
        return try await db.write { db in
            try db.execute(
                sql: sql,
                arguments: [text, failedRaw, errorCode, sessionId, assistantRaw, runningRaw]
            )
            return db.changesCount
        }
    }

    public func messages(sessionId: Int64) async throws -> [ChatMessageRecord] {
        try await db.read { db in
            try ChatMessageRecord.fetchAll(
                db,
                sql: "SELECT * FROM chat_messages WHERE ownerSessionId = ? ORDER BY timestamp ASC, messageId ASC",
                arguments: [sessionId]
            )
        }
    }

    public func deleteMessageById(messageId: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM chat_messages WHERE messageId = ?", arguments: [messageId])
        }
    }

    /* ================= 工具轨迹 ================= */

    @discardableResult
    public func insertToolCall(_ call: ChatToolCallRecord) async throws -> Int64 {
        try await db.write { db in
            try call.insert(db)
            return db.lastInsertedRowID
        }
    }

    public func completeToolCall(id: Int64, status: String, code: String?, durationMs: Int64?) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE chat_tool_calls SET status = ?, code = ?, durationMs = ? WHERE id = ?",
                arguments: [status, code, durationMs, id]
            )
        }
    }

    public func toolCalls(messageId: Int64) async throws -> [ChatToolCallRecord] {
        try await db.read { db in
            try ChatToolCallRecord.fetchAll(
                db,
                sql: "SELECT * FROM chat_tool_calls WHERE messageId = ? ORDER BY position ASC",
                arguments: [messageId]
            )
        }
    }

    public func toolCallsBySession(sessionId: Int64) async throws -> [ChatToolCallRecord] {
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
    public func turns(sessionId: Int64) async throws -> [ChatTurn] {
        let messages = try await messages(sessionId: sessionId)
        let calls = try await toolCallsBySession(sessionId: sessionId)
        var grouped: [Int64: [ChatToolCallRecord]] = [:]
        for call in calls {
            grouped[call.messageId, default: []].append(call)
        }
        return messages.map { ChatTurn(message: $0, toolCalls: grouped[$0.messageId ?? -1] ?? []) }
    }
}
