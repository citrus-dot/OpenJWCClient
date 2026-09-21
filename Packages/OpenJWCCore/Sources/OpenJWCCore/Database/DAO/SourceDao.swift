import Foundation
import GRDB

/// 数据源注册表 + 日报 DAO。SQL 对照 Android `SourceDao`/`DailyReportDao`。
struct SourceDao: Sendable {
    let db: any DatabaseWriter

    /// 置顶排序：subscribed DESC、seu-jwc 置顶、origin DESC、name ASC（照抄 Android）。
    static let orderingSQL =
        "ORDER BY subscribed DESC, CASE WHEN id = 'seu-jwc' THEN 0 ELSE 1 END, origin DESC, name ASC"

    func getAll() async throws -> [NoticeSourceRecord] {
        try await db.read { db in
            try NoticeSourceRecord.fetchAll(db, sql: "SELECT * FROM notice_sources \(Self.orderingSQL)")
        }
    }

    func getById(id: String) async throws -> NoticeSourceRecord? {
        try await db.read { db in
            try NoticeSourceRecord.fetchOne(
                db, sql: "SELECT * FROM notice_sources WHERE id = ? LIMIT 1", arguments: [id]
            )
        }
    }

    func getSubscribed() async throws -> [NoticeSourceRecord] {
        try await db.read { db in
            try NoticeSourceRecord.fetchAll(
                db,
                sql: "SELECT * FROM notice_sources WHERE subscribed = 1 \(Self.orderingSQL)"
            )
        }
    }

    func upsert(_ source: NoticeSourceRecord) async throws {
        try await upsertAll([source])
    }

    func upsertAll(_ sources: [NoticeSourceRecord]) async throws {
        _ = try await db.write { db in
            for s in sources {
                try db.execute(
                    sql: """
                    INSERT INTO notice_sources(id, name, version, origin, scriptFile, domains, labels,
                                               scheduleMinutes, subscribed, lastRunAt, lastCount, lastError) \
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
                    ON CONFLICT(id) DO UPDATE SET \
                        name = excluded.name, version = excluded.version, origin = excluded.origin, \
                        scriptFile = excluded.scriptFile, domains = excluded.domains, labels = excluded.labels, \
                        scheduleMinutes = excluded.scheduleMinutes, subscribed = excluded.subscribed, \
                        lastRunAt = excluded.lastRunAt, lastCount = excluded.lastCount, lastError = excluded.lastError
                    """,
                    arguments: [
                        s.id, s.name, s.version, s.origin, s.scriptFile, s.domains, s.labels,
                        s.scheduleMinutes, s.subscribed, s.lastRunAt, s.lastCount, s.lastError,
                    ]
                )
            }
        }
    }

    func setSubscribed(id: String, subscribed: Bool) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE notice_sources SET subscribed = ? WHERE id = ?",
                arguments: [subscribed, id]
            )
        }
    }

    func updateResult(id: String, timestamp: Int64, count: Int, error: String?) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: """
                UPDATE notice_sources \
                SET lastRunAt = ?, lastCount = ?, lastError = ? WHERE id = ?
                """,
                arguments: [timestamp, count, error, id]
            )
        }
    }

    func deleteById(id: String) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM notice_sources WHERE id = ?", arguments: [id])
        }
    }
}

/// 日报 DAO。
struct DailyReportDao: Sendable {
    let db: any DatabaseWriter

    func get(day: String) async throws -> DailyReportRecord? {
        try await db.read { db in
            try DailyReportRecord.fetchOne(
                db, sql: "SELECT * FROM daily_reports WHERE day = ? LIMIT 1", arguments: [day]
            )
        }
    }

    /// 不晚于 before 的最近一份已完成日报。
    func latestCompleted(before: String) async throws -> DailyReportRecord? {
        try await db.read { db in
            try DailyReportRecord.fetchOne(
                db,
                sql: """
                SELECT * FROM daily_reports WHERE status = 'completed' AND day <= ? \
                ORDER BY day DESC LIMIT 1
                """,
                arguments: [before]
            )
        }
    }

    /// 保存阶段结果；**已完成的日报不会被覆盖**（防降级守卫照抄 Android）。
    func save(day: String, status: String, content: String, sourceCount: Int, error: String?, updatedAt: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: """
                INSERT INTO daily_reports(day, status, content, sourceCount, error, updatedAt) \
                VALUES (?, ?, ?, ?, ?, ?) \
                ON CONFLICT(day) DO UPDATE SET \
                    status = excluded.status, content = excluded.content, \
                    sourceCount = excluded.sourceCount, error = excluded.error, \
                    updatedAt = excluded.updatedAt \
                WHERE daily_reports.status <> 'completed'
                """,
                arguments: [day, status, content, sourceCount, error, updatedAt]
            )
        }
    }

    func clearAll() async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM daily_reports")
        }
    }
}
