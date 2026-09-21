import Foundation
import Testing
@testable import OpenJWCCore

/// Requirement: 资讯检索（Agent 对位）/ 资讯流与收藏
@Suite("NoticeDao")
struct NoticeDaoTests {
    let provider: DatabaseProvider
    let dao: NoticeDao

    init() throws {
        provider = try TestDB.makeInMemory()
        dao = NoticeDao(db: provider.dbWriter)
    }

    private func seed() async throws {
        let notices = [
            notice("a", title: "期末考试安排", content: "关于英语考试的通知", day: "2026-09-01", at: 100),
            notice("b", title: "英语四六级报名", content: "普通正文", day: "2026-09-02", at: 200),
            notice("c", title: "图书馆开放时间", content: "涉及考试周安排调整", day: "2026-09-03", at: 300),
            notice("d", title: "同秒排序", content: "x", day: "2026-09-03", at: 300),
        ]
        try await dao.upsertAll(notices)
    }

    private func notice(_ id: String, title: String, content: String, day: String, at: Int64) -> NoticeRecord {
        NoticeRecord(
            id: id, sourceId: "jwc", label: "教务信息", title: title, publishedAt: at,
            publishedDay: day, detailUrl: "https://x/\(id)", isPage: true,
            content: content, contentVersion: 1, attachments: nil,
            fetchedAt: 1, notified: false, favorite: false
        )
    }

    @Test("标题命中优先于正文命中")
    func relevanceOrdering() async throws {
        try await seed()
        let rows = try await dao.searchNotices(NoticeSearchQuery(query: "考试", relevance: 1, limit: 10))
        // a 标题命中；c 正文命中（b 正文不含"考试"，不命中）
        #expect(rows.count == 2)
        #expect(rows.first?.id == "a") // 标题命中优先
        #expect(rows.dropFirst().map(\.id) == ["c"])
    }

    @Test("分页一致：无重叠且并集为全量")
    func paginationConsistency() async throws {
        try await seed()
        let page1 = try await dao.listByLabel(label: "教务信息", sourceId: nil, limit: 2, offset: 0)
        let page2 = try await dao.listByLabel(label: "教务信息", sourceId: nil, limit: 2, offset: 2)
        let all = try await dao.listByLabel(label: "教务信息", sourceId: nil, limit: 10, offset: 0)
        #expect(Set(page1.map(\.id)).isDisjoint(with: Set(page2.map(\.id))))
        #expect((page1 + page2).map(\.id) == all.map(\.id))
    }

    @Test("资讯流排序：publishedAt DESC, id DESC tie-break")
    func flowOrdering() async throws {
        try await seed()
        let rows = try await dao.listByLabel(label: "教务信息", sourceId: nil, limit: 10, offset: 0)
        // 同 publishedAt=300 的 c/d 稳定排序（d 后写入 → id 更大 → 更靠前）
        #expect(rows.map(\.id) == ["d", "c", "b", "a"])
    }

    @Test("sourceId 过滤")
    func sourceFilter() async throws {
        try await seed()
        let rows = try await dao.listByLabel(label: "教务信息", sourceId: "jwc", limit: 10, offset: 0)
        #expect(rows.count == 4)
        let none = try await dao.listByLabel(label: "教务信息", sourceId: "cs", limit: 10, offset: 0)
        #expect(none.isEmpty)
    }

    @Test("收藏切换与查询")
    func favorites() async throws {
        try await seed()
        try await dao.setFavorite(id: "a", favorite: true)
        #expect(try await dao.isFavorite(id: "a"))
        let favs = try await provider.dbWriter.read { db in
            try NoticeRecord.fetchAll(db, sql: "SELECT * FROM notices WHERE favorite = 1 ORDER BY publishedAt DESC, id DESC")
        }
        #expect(favs.map(\.id) == ["a"])
        try await dao.clearFavorites()
        #expect(!(try await dao.isFavorite(id: "a")))
    }

    @Test("countNotices 与 searchNotices 同口径")
    func countMatchesSearch() async throws {
        try await seed()
        let count = try await dao.countNotices(query: "考试", label: "", sourceId: nil, fromDay: "", toDay: "", favoriteOnly: 0)
        let rows = try await dao.searchNotices(NoticeSearchQuery(query: "考试", relevance: 1, limit: 100))
        #expect(count == rows.count)
    }

    @Test("idsWithContentBySource 按 contentVersion 判定补抓")
    func contentVersionGate() async throws {
        try await seed()
        let ids = try await dao.idsWithContentBySource(sourceId: "jwc", minVersion: 1)
        #expect(Set(ids) == ["a", "b", "c", "d"])
        var stale = notice("e", title: "旧格式", content: "旧正文", day: "2026-09-04", at: 400)
        stale.contentVersion = 0
        let staleCopy = stale
        try await dao.upsertAll([staleCopy])
        let after = try await dao.idsWithContentBySource(sourceId: "jwc", minVersion: 1)
        #expect(!after.contains("e"))
    }

    @Test("idsByDay 与 min/maxDay")
    func dayQueries() async throws {
        try await seed()
        let ids = try await dao.idsByDay(day: "2026-09-03")
        #expect(Set(ids) == ["c", "d"])
        #expect(try await dao.minDay() == "2026-09-01")
        #expect(try await dao.maxDay() == "2026-09-03")
    }

    @Test("upsert 覆盖既有行")
    func upsertOverwrites() async throws {
        try await seed()
        var updated = notice("a", title: "期末考试安排（修订）", content: "x", day: "2026-09-01", at: 100)
        updated.favorite = true
        let updatedCopy = updated
        try await dao.upsertAll([updatedCopy])
        let row = try await dao.findById(id: "a")
        #expect(row?.title == "期末考试安排（修订）")
        #expect(row?.favorite == true)
        let total = try await dao.totalCount()
        #expect(total == 4)
    }
}

/// Requirement: WAL 池化打开
@Suite("WAL")
struct WALTests {
    @Test("临时文件池并发读写不阻塞且数据一致")
    func concurrentReadWrite() async throws {
        let (provider, url) = try TestDB.makeTempPool()
        defer { TestDB.cleanup(url) }
        let dao = NoticeDao(db: provider.dbWriter)

        try await dao.upsertAll([
            NoticeRecord(
                id: "w1", sourceId: "jwc", label: "L", title: "并发", publishedAt: 1,
                publishedDay: "2026-09-01", detailUrl: "u", isPage: true, content: "c",
                contentVersion: 1, attachments: nil, fetchedAt: 1, notified: false, favorite: false
            ),
        ])

        // 写事务进行时并发读（WAL 语义：读写互不阻塞）
        async let writer: Void = dao.upsertAll([
            NoticeRecord(
                id: "w2", sourceId: "jwc", label: "L", title: "并发2", publishedAt: 2,
                publishedDay: "2026-09-01", detailUrl: "u", isPage: true, content: "c",
                contentVersion: 1, attachments: nil, fetchedAt: 1, notified: false, favorite: false
            ),
        ])
        async let reader: Int = dao.totalCount()
        let (_, countDuringWrite) = try await (writer, reader)
        #expect(countDuringWrite >= 1)

        let final = try await dao.totalCount()
        #expect(final == 2)
    }
}
