import Foundation
import GRDB

/// 栏目及其条数（对齐 Android `LabelCount`）。
struct LabelCount: Equatable {
    var label: String
    var labelCount: Int
}

/// 数据源及其本地语料条数（对齐 Android `SourceCount`）。
struct SourceCount: Equatable {
    var sourceId: String?
    var noticeCount: Int
}

/// Agent 检索参数：哨兵语义照抄 Android `searchNotices`
/// （query/label/fromDay/toDay 空串、sourceId nil、favoriteOnly/relevance 0 = 不过滤/关闭）。
struct NoticeSearchQuery: Equatable {
    var query: String = ""
    var label: String = ""
    var sourceId: String? = nil
    var fromDay: String = ""
    var toDay: String = ""
    var favoriteOnly: Int = 0
    var relevance: Int = 0
    var limit: Int
    var offset: Int = 0
}

/// 本地资讯语料 DAO：资讯流、收藏、通知水位、Agent 检索共用。
/// SQL 逐条对照 Android `NoticeDao`（LIKE 检索不用 FTS 的理由同 Android：SQLite 默认分词器切不了中文）。
struct NoticeDao: Sendable {
    let db: any DatabaseWriter

    /* ================= 资讯流 ================= */

    static let listByLabelSQL = """
        SELECT * FROM notices WHERE label = ? AND (? IS NULL OR sourceId = ?) \
        ORDER BY publishedAt DESC, id DESC LIMIT ? OFFSET ?
        """

    public func listByLabel(label: String, sourceId: String?, limit: Int, offset: Int) async throws -> [NoticeRecord] {
        try await db.read { db in
            try NoticeRecord.fetchAll(
                db,
                sql: Self.listByLabelSQL,
                arguments: [label, sourceId, sourceId, limit, offset]
            )
        }
    }

    func totalCount() async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notices") ?? 0
        }
    }

    func clearAll() async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM notices")
        }
    }

    /* ================= 写入（@Upsert 语义） ================= */

    func upsertAll(_ items: [NoticeRecord]) async throws {
        _ = try await db.write { db in
            for item in items {
                try db.execute(
                    sql: """
                    INSERT INTO notices(id, sourceId, label, title, publishedAt, publishedDay,
                                        detailUrl, isPage, content, contentVersion, attachments,
                                        fetchedAt, notified, favorite)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        sourceId = excluded.sourceId, label = excluded.label, title = excluded.title,
                        publishedAt = excluded.publishedAt, publishedDay = excluded.publishedDay,
                        detailUrl = excluded.detailUrl, isPage = excluded.isPage, content = excluded.content,
                        contentVersion = excluded.contentVersion, attachments = excluded.attachments,
                        fetchedAt = excluded.fetchedAt, notified = excluded.notified, favorite = excluded.favorite
                    """,
                    arguments: [
                        item.id, item.sourceId, item.label, item.title, item.publishedAt, item.publishedDay,
                        item.detailUrl, item.isPage, item.content, item.contentVersion, item.attachments,
                        item.fetchedAt, item.notified, item.favorite,
                    ]
                )
            }
        }
    }

    func selectFavoriteIds(ids: [String]) async throws -> [String] {
        try await idsFiltering(ids, column: "favorite")
    }

    func selectNotifiedIds(ids: [String]) async throws -> [String] {
        try await idsFiltering(ids, column: "notified")
    }

    private func idsFiltering(_ ids: [String], column: String) async throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        return try await db.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM notices WHERE id IN (\(placeholders)) AND \(column) = 1",
                arguments: StatementArguments(ids)
            )
        }
    }

    func markFavorites(ids: [String]) async throws {
        try await markFlag(ids: ids, column: "favorite", value: true)
    }

    func markNotified(ids: [String]) async throws {
        try await markFlag(ids: ids, column: "notified", value: true)
    }

    private func markFlag(ids: [String], column: String, value: Bool) async throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE notices SET \(column) = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments([value] + ids)
            )
        }
    }

    /* ================= 收藏 ================= */

    func setFavorite(id: String, favorite: Bool) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "UPDATE notices SET favorite = ? WHERE id = ?", arguments: [favorite, id])
        }
    }

    func clearFavorites() async throws {
        _ = try await db.write { db in
            try db.execute(sql: "UPDATE notices SET favorite = 0")
        }
    }

    func isFavorite(id: String) async throws -> Bool {
        try await db.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM notices WHERE id = ? AND favorite = 1)",
                arguments: [id]
            ) ?? false
        }
    }

    /* ================= 通知水位 ================= */

    func idsBySource(sourceId: String) async throws -> [String] {
        try await db.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM notices WHERE sourceId = ?", arguments: [sourceId])
        }
    }

    func notifiedIdsBySource(sourceId: String) async throws -> [String] {
        try await db.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM notices WHERE sourceId = ? AND notified = 1",
                arguments: [sourceId]
            )
        }
    }

    func countBySource(sourceId: String) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notices WHERE sourceId = ?",
                arguments: [sourceId]
            ) ?? 0
        }
    }

    /* ================= Agent 检索（SQL 原样对照 Android searchNotices/countNotices） ================= */

    static let searchWhereSQL = """
        (? = '' OR title LIKE '%' || ? || '%' OR content LIKE '%' || ? || '%') \
        AND (? = '' OR label = ?) \
        AND (? IS NULL OR sourceId = ?) \
        AND (? = '' OR publishedDay >= ?) \
        AND (? = '' OR publishedDay <= ?) \
        AND (? = 0 OR favorite = 1)
        """

    private static func searchArguments(_ q: NoticeSearchQuery, includeOrdering: Bool) -> StatementArguments {
        var args: [(any DatabaseValueConvertible)?] = [
            q.query, q.query, q.query,
            q.label, q.label,
            q.sourceId, q.sourceId,
            q.fromDay, q.fromDay,
            q.toDay, q.toDay,
            q.favoriteOnly,
        ]
        if includeOrdering {
            args.append(q.relevance)
            args.append(q.query)
            args.append(q.query)
            args.append(q.limit)
            args.append(q.offset)
        }
        return StatementArguments(args)
    }

    func searchNotices(_ q: NoticeSearchQuery) async throws -> [NoticeRecord] {
        try await db.read { db in
            try NoticeRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM notices WHERE \(Self.searchWhereSQL) \
                ORDER BY \
                  CASE WHEN ? = 1 AND ? <> '' AND title LIKE '%' || ? || '%' THEN 0 ELSE 1 END, \
                  publishedAt DESC, id DESC \
                LIMIT ? OFFSET ?
                """,
                arguments: Self.searchArguments(q, includeOrdering: true)
            )
        }
    }

    func countNotices(query: String, label: String, sourceId: String?, fromDay: String, toDay: String, favoriteOnly: Int) async throws -> Int {
        let q = NoticeSearchQuery(
            query: query, label: label, sourceId: sourceId,
            fromDay: fromDay, toDay: toDay, favoriteOnly: favoriteOnly,
            relevance: 0, limit: 0, offset: 0
        )
        return try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notices WHERE \(Self.searchWhereSQL)",
                             arguments: Self.searchArguments(q, includeOrdering: false)) ?? 0
        }
    }

    /// 已有正文（或不需要正文）的条目 id；正文为空的条目留给脚本重试补全。
    func idsWithContentBySource(sourceId: String, minVersion: Int) async throws -> [String] {
        try await db.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT id FROM notices WHERE sourceId = ? \
                AND ((content IS NOT NULL AND content <> '' AND contentVersion >= ?) OR isPage = 0)
                """,
                arguments: [sourceId, minVersion]
            )
        }
    }

    /// 某日发布的资讯 id（日报用）。
    func idsByDay(day: String) async throws -> [String] {
        try await db.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM notices WHERE publishedDay = ? ORDER BY publishedAt, id",
                arguments: [day]
            )
        }
    }

    func findById(id: String) async throws -> NoticeRecord? {
        try await db.read { db in
            try NoticeRecord.fetchOne(db, sql: "SELECT * FROM notices WHERE id = ? LIMIT 1", arguments: [id])
        }
    }

    func distinctLabels() async throws -> [String] {
        try await db.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT label FROM notices WHERE label <> '' ORDER BY label"
            )
        }
    }

    func distinctLabelsBySource(sourceId: String?) async throws -> [String] {
        try await db.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT label FROM notices WHERE label <> '' \
                AND (? IS NULL OR sourceId = ?) ORDER BY label
                """,
                arguments: [sourceId, sourceId]
            )
        }
    }

    func labelCounts() async throws -> [LabelCount] {
        try await db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT label, COUNT(*) AS labelCount FROM notices WHERE label <> '' GROUP BY label ORDER BY label"
            )
            return rows.map { LabelCount(label: $0["label"], labelCount: $0["labelCount"]) }
        }
    }

    func minDay() async throws -> String? {
        try await db.read { db in
            try String.fetchOne(db, sql: "SELECT MIN(publishedDay) FROM notices WHERE publishedDay <> ''")
        }
    }

    func maxDay() async throws -> String? {
        try await db.read { db in
            try String.fetchOne(db, sql: "SELECT MAX(publishedDay) FROM notices WHERE publishedDay <> ''")
        }
    }
}
