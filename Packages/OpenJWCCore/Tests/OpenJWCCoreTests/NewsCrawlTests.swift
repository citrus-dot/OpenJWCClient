import Testing
import Foundation
import GRDB
@testable import OpenJWCCore

/// NewsCrawlService 测试（tasks 组 4）：事件序 / 防重入 / 取消 / 运行结果回写 / 收藏与水位保留。
/// 用 Fixtures/CrawlSources 假脚本（ok/slow/fail），不需要网络。
@Suite("NewsCrawlService 抓取编排")
struct NewsCrawlTests {

    private func makeTempDB() throws -> DatabaseProvider {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openjwc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DatabaseProvider(databasePath: dir.appendingPathComponent("test.sqlite").path)
    }

    private func crawlDirectory() throws -> URL {
        let root = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/CrawlSources")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ok.js").path))
        return root
    }

    private func makeService(_ db: DatabaseProvider, host: JavaScriptHost = JavaScriptHost()) -> NewsCrawlService {
        NewsCrawlService(db: db.dbWriter, host: host) { source in
            guard let file = source.scriptFile else {
                throw ScriptError.execution("无脚本文件")
            }
            return try String(
                contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/CrawlSources/\(file)"),
                encoding: .utf8
            )
        }
    }

    private func source(_ id: String, _ file: String, _ name: String = "") -> NoticeSourceRecord {
        NoticeSourceRecord(
            id: id, name: name.isEmpty ? id : name, version: "1.0.0", origin: "builtin",
            scriptFile: file, domains: JSONStringList(["example.com"]),
            labels: JSONStringList(["通知"]), scheduleMinutes: 60,
            subscribed: true, lastRunAt: nil, lastCount: 0, lastError: nil
        )
    }

    private func collectEvents(_ service: NewsCrawlService, sources: [NoticeSourceRecord]) async -> [CrawlEvent] {
        var events: [CrawlEvent] = []
        let stream = await service.crawl(sources: sources, crawlDaysGap: 200)
        for await event in stream {
            events.append(event)
        }
        return events
    }

    @Test("事件序：started → sourceStarted → sourceFinished → finished")
    func eventSequence() async throws {
        let db = try makeTempDB()
        let service = makeService(db)

        let events = await collectEvents(service, sources: [source("crawl-ok", "ok.js", "正常源")])

        guard case .started(let total) = events.first else {
            Issue.record("首事件应为 started"); return
        }
        #expect(total == 1)
        guard case .sourceStarted(let sid, let sname, let index, let total2) = events.dropFirst().first else {
            Issue.record("第二事件应为 sourceStarted"); return
        }
        #expect(sid == "crawl-ok" && sname == "正常源" && index == 0 && total2 == 1)
        guard case .sourceFinished(let fid, _, let summary, let success) = events.dropFirst(2).first else {
            Issue.record("第三事件应为 sourceFinished"); return
        }
        #expect(fid == "crawl-ok" && success && summary.contains("新增 2 条"))
        guard case .finished(let cancelled) = events.last else {
            Issue.record("末事件应为 finished"); return
        }
        #expect(!cancelled)
        #expect(events.count == 4)
    }

    @Test("防重入：抓取进行中再次触发得到空流")
    func reentrancyGuard() async throws {
        let db = try makeTempDB()
        let service = makeService(db)

        let first = await service.crawl(sources: [source("crawl-slow", "slow.js")], crawlDaysGap: 200)
        let consumer = Task { () -> Bool in
            for await event in first {
                if case .started = event { return true }
            }
            return false
        }
        // 等第一个抓取真正跑起来（slow 脚本 busy loop 3s）
        var waited = 0
        while !(await service.running) && waited < 3000 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
        #expect(await service.running)

        let second = await service.crawl(sources: [source("crawl-ok", "ok.js")], crawlDaysGap: 200)
        var secondEvents = 0
        for await _ in second { secondEvents += 1 }
        #expect(secondEvents == 0)

        let sawStarted = await consumer.value
        #expect(sawStarted)
    }

    @Test("用户取消：剩余源不再抓取，已落库结果保留")
    func cancellation() async throws {
        let db = try makeTempDB()
        let service = makeService(db)
        let dao = SourceDao(db: db.dbWriter)

        let stream = await service.crawl(
            sources: [source("crawl-slow", "slow.js"), source("crawl-ok", "ok.js")],
            crawlDaysGap: 200
        )
        let consumer = Task {
            for await _ in stream {}
        }
        // 收到 started 后立即取消
        try await Task.sleep(for: .milliseconds(150))
        consumer.cancel()
        _ = await consumer.result

        // 后面的源完全没有被碰
        let ok = try await dao.getById(id: "crawl-ok")
        #expect(ok?.lastRunAt == nil)
    }

    @Test("成功落库：contentVersion/收藏保留/水位基线/lastRunAt 回写")
    func successPersistAndGuards() async throws {
        let db = try makeTempDB()
        let service = makeService(db)
        let noticeDao = NoticeDao(db: db.dbWriter)
        let dao = SourceDao(db: db.dbWriter)

        // 源先入库（updateResult 是 UPDATE 语句，行必须存在）
        try await dao.upsert(source("crawl-ok", "ok.js", "正常源"))

        // 预置一条旧格式（contentVersion=0）且已收藏的同 id 记录：重抓应刷新正文并保留收藏
        let stale = NoticeRecord(
            id: "n1", sourceId: "crawl-ok", label: "通知", title: "旧标题",
            publishedAt: 0, publishedDay: "", detailUrl: "https://example.com/1", isPage: true,
            content: nil, contentVersion: 0, attachments: nil, fetchedAt: 1,
            notified: false, favorite: true
        )
        try await noticeDao.upsertAll([stale])

        let events = await collectEvents(service, sources: [source("crawl-ok", "ok.js")])
        guard case .sourceFinished(_, _, _, let success)? = events.first(where: {
            if case .sourceFinished = $0 { return true } else { return false }
        }) else {
            Issue.record("缺 sourceFinished"); return
        }
        #expect(success)

        let n1 = try #require(try await noticeDao.findById(id: "n1"))
        #expect(n1.contentVersion == 1)
        #expect(n1.title == "第一条")
        #expect(n1.favorite) // 用户态保留
        // 已存在但未通知过的条目：settleNotifications 不触碰（仅新增/基线标记已读）
        #expect(!n1.notified)
        #expect(n1.publishedAt > 0)
        #expect(n1.publishedDay == "2026-09-21")

        // n2 是新增条目：交互抓取视为已读
        let n2 = try #require(try await noticeDao.findById(id: "n2"))
        #expect(n2.notified)
        #expect(!n2.favorite)

        let source = try #require(try await dao.getById(id: "crawl-ok"))
        #expect(source.lastRunAt != nil)
        #expect(source.lastCount == 2)
        #expect(source.lastError == nil)
    }

    @Test("失败源：结果回写 error，资讯不落库")
    func failureWritesResult() async throws {
        let db = try makeTempDB()
        let service = makeService(db)
        let dao = SourceDao(db: db.dbWriter)
        let noticeDao = NoticeDao(db: db.dbWriter)

        try await dao.upsert(source("crawl-fail", "fail.js", "失败源"))

        let events = await collectEvents(service, sources: [source("crawl-fail", "fail.js")])
        guard case .sourceFinished(_, _, let summary, let success)? = events.first(where: {
            if case .sourceFinished = $0 { return true } else { return false }
        }) else {
            Issue.record("缺 sourceFinished"); return
        }
        #expect(!success)
        #expect(summary.contains("boom"))

        let failed = try #require(try await dao.getById(id: "crawl-fail"))
        #expect(failed.lastRunAt != nil)
        #expect(failed.lastCount == 0)
        #expect(failed.lastError?.contains("boom") == true)
        #expect(try await noticeDao.totalCount() == 0)
    }

    @Test("日期解析：多 formatter 对齐 Android，失败为 0")
    func dateParsing() {
        #expect(NewsCrawlService.parseDateSortKey("2026-09-21 10:00:00") > 0)
        #expect(NewsCrawlService.parseDateSortKey("2026-09-21 10:00") > 0)
        #expect(NewsCrawlService.parseDateSortKey("2026-09-21T10:00:00") > 0)
        #expect(NewsCrawlService.parseDateSortKey("2026-09-21") > 0)
        #expect(NewsCrawlService.parseDateSortKey("") == 0)
        #expect(NewsCrawlService.parseDateSortKey("垃圾") == 0)
        #expect(NewsCrawlService.parseDateSortKey("2026-09-21") > NewsCrawlService.parseDateSortKey("2026-09-20"))
    }
}
