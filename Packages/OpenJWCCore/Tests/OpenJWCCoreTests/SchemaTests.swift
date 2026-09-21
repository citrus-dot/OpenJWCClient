import Foundation
import Testing
import GRDB
@testable import OpenJWCCore

/// 测试公共工具：in-memory 库 + 临时文件池工厂。
enum TestDB {
    static func makeInMemory() throws -> DatabaseProvider {
        try DatabaseProvider(inMemory: true)
    }

    /// WAL 并发语义必须用临时文件 DatabasePool（:memory: 的多连接互不可见）。
    static func makeTempPool() throws -> (DatabaseProvider, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openjwc-test-\(UUID().uuidString).sqlite")
        let provider = try DatabaseProvider(databasePath: url.path)
        return (provider, url)
    }

    static func cleanup(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}

/// Requirement: SQLite schema 与 Android Room v14 对齐
@Suite("Schema")
struct SchemaTests {
    @Test("首次启动建表：8 张表全部存在")
    func tablesCreated() async throws {
        let provider = try TestDB.makeInMemory()
        let tables = try await provider.dbWriter.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name"
            )
        }
        #expect(Set(tables) == [
            "notices", "daily_reports", "notice_sources",
            "chat_metadata", "chat_messages", "chat_tool_calls",
            "courses", "table_metadata",
        ])
    }

    @Test("notices 索引与 Android 一致")
    func noticeIndexes() async throws {
        let provider = try TestDB.makeInMemory()
        let indexes = try await provider.dbWriter.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='notices' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            )
        }
        #expect(Set(indexes) == [
            "index_notices_publishedAt", "index_notices_publishedDay",
            "index_notices_label_publishedAt", "index_notices_sourceId",
        ])
    }

    @Test("删除会话级联清理消息与工具卡")
    func sessionCascade() async throws {
        let provider = try TestDB.makeInMemory()
        let chat = ChatDao(db: provider.dbWriter)
        let sessionId = try await chat.insertMetadata(ChatSessionRecord(title: "s", lastUpdated: 1))
        let messageId = try await chat.insertMessage(ChatMessageRecord(
                messageId: nil, ownerSessionId: sessionId, text: "hi", role: .user,
                attachmentTitles: JSONStringList([]), attachmentIds: JSONStringList([]),
                status: .completed, runId: nil, delivery: nil, errorCode: nil, timestamp: 1
            ))
        _ = try await chat.insertToolCall(ChatToolCallRecord(
                id: nil, messageId: messageId, position: 0, name: "search_notices",
                summary: "", status: "RUNNING", code: nil, durationMs: nil, targetId: nil
            ))
        try await chat.deleteSession(sessionId: sessionId)
        let remaining = try await provider.dbWriter.read { db in
            (
                try ChatSessionRecord.fetchCount(db),
                try ChatMessageRecord.fetchCount(db),
                try ChatToolCallRecord.fetchCount(db)
            )
        }
        #expect(remaining == (0, 0, 0))
    }

    @Test("删除课表级联删除课程")
    func tableCascade() async throws {
        let provider = try TestDB.makeInMemory()
        let dao = TimetableDao(db: provider.dbWriter)
        let tableId = try await dao.insertTable(TableMetadataRecord(
                id: nil, tableName: "T", semesterConfig: SemesterConfig(startDate: "", weeks: 16, visibleDays: [], periods: []), isCurrent: true
            ))
        try await dao.upsertCourse(dummyCourse(tableId: tableId))
        try await dao.deleteTableById(tableId: tableId)
        let courseCount = try await provider.dbWriter.read { db in try CourseRecord.fetchCount(db) }
        #expect(courseCount == 0)
    }

    private func dummyCourse(tableId: Int64) -> CourseRecord {
        CourseRecord(
            id: nil, tableId: tableId, name: "C", teacher: "", location: "",
            dayOfWeek: 1, startPeriod: 1, duration: 2, color: -1, weekRule: JSONIntSet([1]), note: ""
        )
    }
}
