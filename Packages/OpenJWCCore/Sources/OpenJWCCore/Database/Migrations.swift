import Foundation
import GRDB

/// 终态 schema（对齐 Android Room v14）。
/// 每张表的列/索引/外键逐字段对照 `AppDatabase.kt` 各迁移 DDL 的最终形态：
/// - notices ← MIGRATION_9_10 + 12_13（contentVersion）
/// - daily_reports ← MIGRATION_9_10 + 11_12（error）
/// - chat_messages ← v1 原始 + 6_7（attachmentIds）+ 10_11（status/runId/delivery/errorCode）
/// - chat_tool_calls ← 10_11 + 13_14（targetId）
/// - notice_sources ← 7_8；courses/table_metadata ← 4_5；chat_metadata ← v1
enum Migrations {
    static func registerAll(to migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1-final") { db in
            try db.create(table: "chat_metadata") { t in
                t.autoIncrementedPrimaryKey("sessionId")
                t.column("title", .text).notNull()
                t.column("lastUpdated", .integer).notNull()
            }

            try db.create(table: "chat_messages") { t in
                t.autoIncrementedPrimaryKey("messageId")
                t.column("ownerSessionId", .integer)
                    .notNull()
                    .references("chat_metadata", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("role", .text).notNull()
                t.column("attachmentTitles", .text).notNull().defaults(to: "[]")
                t.column("attachmentIds", .text).notNull().defaults(to: "[]")
                t.column("status", .text).notNull().defaults(to: "COMPLETED")
                t.column("runId", .text)
                t.column("delivery", .text)
                t.column("errorCode", .text)
                t.column("timestamp", .integer).notNull()
            }
            try db.create(index: "index_chat_messages_ownerSessionId",
                          on: "chat_messages", columns: ["ownerSessionId"])

            try db.create(table: "chat_tool_calls") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("messageId", .integer)
                    .notNull()
                    .references("chat_messages", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("status", .text).notNull()
                t.column("code", .text)
                t.column("durationMs", .integer)
                t.column("targetId", .text)
            }
            try db.create(index: "index_chat_tool_calls_messageId",
                          on: "chat_tool_calls", columns: ["messageId"])

            try db.create(table: "notices") { t in
                t.column("id", .text).primaryKey()
                t.column("sourceId", .text)
                t.column("label", .text).notNull()
                t.column("title", .text).notNull()
                t.column("publishedAt", .integer).notNull()
                t.column("publishedDay", .text).notNull()
                t.column("detailUrl", .text).notNull()
                t.column("isPage", .boolean).notNull()
                t.column("content", .text)
                t.column("contentVersion", .integer).notNull().defaults(to: 0)
                t.column("attachments", .text)
                t.column("fetchedAt", .integer).notNull()
                t.column("notified", .boolean).notNull()
                t.column("favorite", .boolean).notNull()
            }
            try db.create(index: "index_notices_publishedAt", on: "notices", columns: ["publishedAt"])
            try db.create(index: "index_notices_publishedDay", on: "notices", columns: ["publishedDay"])
            try db.create(index: "index_notices_label_publishedAt",
                          on: "notices", columns: ["label", "publishedAt"])
            try db.create(index: "index_notices_sourceId", on: "notices", columns: ["sourceId"])

            try db.create(table: "daily_reports") { t in
                t.column("day", .text).primaryKey()
                t.column("status", .text).notNull()
                t.column("content", .text).notNull()
                t.column("sourceCount", .integer).notNull()
                t.column("error", .text)
                t.column("updatedAt", .integer).notNull()
            }

            try db.create(table: "table_metadata") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tableName", .text).notNull()
                t.column("semesterConfig", .text).notNull()
                t.column("isCurrent", .boolean).notNull()
            }

            try db.create(table: "courses") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tableId", .integer)
                    .notNull()
                    .references("table_metadata", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("teacher", .text).notNull()
                t.column("location", .text).notNull()
                t.column("dayOfWeek", .integer).notNull()
                t.column("startPeriod", .integer).notNull()
                t.column("duration", .integer).notNull()
                t.column("color", .integer).notNull()
                t.column("weekRule", .text).notNull()
                t.column("note", .text).notNull()
            }
            try db.create(index: "index_courses_tableId", on: "courses", columns: ["tableId"])

            try db.create(table: "notice_sources") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("version", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("scriptFile", .text)
                t.column("domains", .text).notNull()
                t.column("labels", .text).notNull()
                t.column("scheduleMinutes", .integer).notNull()
                t.column("subscribed", .boolean).notNull()
                t.column("lastRunAt", .integer)
                t.column("lastCount", .integer).notNull()
                t.column("lastError", .text)
            }
        }
    }
}
