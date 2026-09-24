import Testing
import Foundation
import GRDB
@testable import OpenJWCCore

/// 阶段 7a core 单测：CrawlEvent.newNotices 外传（组 1.3）、WidgetSnapshot 编解码（组 2.3）、
/// CourseReminderPlan 提醒计划（组 3.4）。文案与语义对齐 spec/design D-4/D-5/D-7。
@Suite("平台集成 7a core")
struct PlatformIntegrationTests {

    // MARK: - 组 1.3 newNotices 外传

    @Suite("CrawlEvent.newNotices")
    struct NewNoticesTests {

        private func makeTempDB() throws -> DatabaseProvider {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("openjwc-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return try DatabaseProvider(databasePath: dir.appendingPathComponent("test.sqlite").path)
        }

        private func makeService(_ db: DatabaseProvider) -> NewsCrawlService {
            NewsCrawlService(db: db.dbWriter) { source in
                guard let file = source.scriptFile else { throw ScriptError.execution("无脚本文件") }
                return try String(
                    contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/CrawlSources/\(file)"),
                    encoding: .utf8
                )
            }
        }

        private func okSource() -> NoticeSourceRecord {
            NoticeSourceRecord(
                id: "crawl-ok", name: "正常源", version: "1.0.0", origin: "builtin",
                scriptFile: "ok.js", domains: JSONStringList(["example.com"]),
                labels: JSONStringList(["通知"]), scheduleMinutes: 60,
                subscribed: true, lastRunAt: nil, lastCount: 0, lastError: nil
            )
        }

        @Test("baseline 首抓不发 newNotices，全部条目标水位")
        func baselineSilent() async throws {
            let db = try makeTempDB()
            let service = makeService(db)
            let noticeDao = NoticeDao(db: db.dbWriter)

            var events: [CrawlEvent] = []
            let stream = await service.crawl(sources: [okSource()], crawlDaysGap: 200)
            for await event in stream { events.append(event) }

            #expect(!events.contains { if case .newNotices = $0 { return true } else { return false } })
            for id in ["n1", "n2"] {
                let record = try #require(try await noticeDao.findById(id: id))
                #expect(record.notified)
            }
        }

        @Test("新增条目发 newNotices 且照常标水位；已存在条目不触碰")
        func newNoticesYielded() async throws {
            let db = try makeTempDB()
            let service = makeService(db)
            let noticeDao = NoticeDao(db: db.dbWriter)
            let dao = SourceDao(db: db.dbWriter)
            try await dao.upsert(okSource())

            // 预置 stale n1（contentVersion=0 → 已知条目，重抓后仍非新增）
            let stale = NoticeRecord(
                id: "n1", sourceId: "crawl-ok", label: "通知", title: "旧标题",
                publishedAt: 0, publishedDay: "", detailUrl: "https://example.com/1", isPage: true,
                content: nil, contentVersion: 0, attachments: nil, fetchedAt: 1,
                notified: false, favorite: false
            )
            try await noticeDao.upsertAll([stale])

            var events: [CrawlEvent] = []
            let stream = await service.crawl(sources: [okSource()], crawlDaysGap: 200)
            for await event in stream { events.append(event) }

            let newEvents = events.compactMap { event -> [NoticeBrief]? in
                if case .newNotices(_, let notices) = event { return notices } else { return nil }
            }
            #expect(newEvents.count == 1)
            #expect(newEvents.first == [NoticeBrief(id: "n2", title: "第二条", label: "通知")])

            // 水位语义不变：新增条目标已通知，已存在条目不触碰
            let n2 = try #require(try await noticeDao.findById(id: "n2"))
            #expect(n2.notified)
            let n1 = try #require(try await noticeDao.findById(id: "n1"))
            #expect(!n1.notified)
        }
    }

    // MARK: - 组 2.3 WidgetSnapshot 编解码

    @Suite("WidgetSnapshot 快照")
    struct SnapshotTests {

        private func sampleSnapshot() -> WidgetSnapshot {
            WidgetSnapshot(
                tableId: 7, tableName: "2026 秋", startDate: "2026-09-07",
                totalWeeks: 20,
                periods: [
                    .init(start: "08:00", end: "08:45"),
                    .init(start: "08:55", end: "09:40"),
                ],
                courses: [
                    .init(
                        id: 11, name: "高等数学", teacher: "张老师", location: "A101",
                        dayOfWeek: 1, startPeriod: 1, duration: 2, color: 0xFF3B30,
                        weekRule: [1, 2, 3, 4]
                    ),
                ]
            )
        }

        @Test("编码 → 解码回环")
        func roundTrip() throws {
            let snapshot = sampleSnapshot()
            let data = try #require(snapshot.encodeJSON())
            let decoded = try #require(WidgetSnapshot.decode(data))
            #expect(decoded == snapshot)
        }

        @Test("宽容读：未知版本 / 缺字段 / 文件不存在 → 空态")
        func lenientRead() throws {
            let future = Data(#"{"schemaVersion":99,"tableId":1}"#.utf8)
            #expect(WidgetSnapshot.decode(future) == nil)

            let missing = Data(#"{"tableId":1}"#.utf8)
            #expect(WidgetSnapshot.decode(missing) == nil)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("openjwc-snapshot-\(UUID().uuidString).json")
            #expect(WidgetSnapshot.read(from: url) == nil)
        }

        @Test("原子写：写入后可读回且内容一致")
        func atomicWrite() throws {
            let snapshot = sampleSnapshot()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("openjwc-snapshot-\(UUID().uuidString).json")
            #expect(snapshot.write(to: url))
            let readBack = try #require(WidgetSnapshot.read(from: url))
            #expect(readBack == snapshot)

            // 覆盖写
            var updated = snapshot
            updated.tableName = "2026 春"
            #expect(updated.write(to: url))
            #expect(WidgetSnapshot.read(from: url)?.tableName == "2026 春")
        }
    }

    // MARK: - 组 3.4 CourseReminderPlan

    @Suite("CourseReminderPlan 提醒计划")
    struct ReminderPlanTests {

        private static let tz = TimeZone(identifier: "Asia/Shanghai")!
        /// 2026-09-07 是周一；2026-09-24（周四）位于第 3 周；窗口内下个周一 09-28 为第 4 周。
        private static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            return cal.date(from: DateComponents(
                timeZone: tz, year: y, month: mo, day: d, hour: h, minute: mi
            ))!
        }

        private static func snapshot(courses: [WidgetSnapshot.Course]) -> WidgetSnapshot {
            WidgetSnapshot(
                tableId: 7, tableName: "2026 秋", startDate: "2026-09-07",
                totalWeeks: 20,
                periods: [
                    .init(start: "08:00", end: "09:35"),
                    .init(start: "10:00", end: "11:35"),
                    .init(start: "14:00", end: "15:35"),
                ],
                courses: courses
            )
        }

        private func build(
            _ snapshot: WidgetSnapshot, now: Date,
            windowDays: Int = 14, limit: Int = 64
        ) -> [CourseReminderPlan.Item] {
            CourseReminderPlan.build(
                snapshot: snapshot, now: now,
                timeZone: Self.tz, windowDays: windowDays, limit: limit
            )
        }

        @Test("提前 10 分钟：周一第 1 节 08:00 课 → fire 07:50；内容四段格式")
        func leadTimeAndContent() {
            let now = Self.date(2026, 9, 24, 10, 0) // 周四 10:00（第 3 周）
            let course = WidgetSnapshot.Course(
                id: 11, name: "高等数学", teacher: "张老师", location: "A101",
                dayOfWeek: 1, startPeriod: 1, duration: 1, color: 1, weekRule: [3, 4]
            )
            let items = build(Self.snapshot(courses: [course]), now: now)

            // 09-29（下周二）不在窗口匹配日；命中 09-28（第 4 周周一）
            #expect(items.count == 1)
            let item = items[0]
            let fire = Self.date(2026, 9, 28, 7, 50)
            #expect(item.fireDate == fire)
            #expect(item.title == "课程还有 10 分钟开始")
            #expect(item.body == "高等数学 · 08:00-09:35 · A101 · 张老师")
            #expect(item.identifier == "course-7-11-4-\(Int64(fire.timeIntervalSince1970 * 1000) + 600_000)")
        }

        @Test("窗口边界：已过时刻跳过；超窗（fireDate > now+窗口末）跳过")
        func windowBoundaries() {
            let now = Self.date(2026, 9, 24, 10, 0) // 周四 10:00（第 3 周），窗口 1 天 = 09-25 10:00

            // 当天 08:00 课 fire=07:50 已过 → 跳过
            let past = WidgetSnapshot.Course(
                id: 11, name: "早课", teacher: "", location: "",
                dayOfWeek: 4, startPeriod: 1, duration: 1, color: 1, weekRule: [3]
            )
            #expect(build(Self.snapshot(courses: [past]), now: now, windowDays: 1).isEmpty)

            // 当天 14:00 课 fire=13:50 ≤ 窗口末 → 保留
            let today = WidgetSnapshot.Course(
                id: 12, name: "午后课", teacher: "", location: "",
                dayOfWeek: 4, startPeriod: 3, duration: 1, color: 1, weekRule: [3]
            )
            #expect(build(Self.snapshot(courses: [today]), now: now, windowDays: 1).count == 1)

            // 超窗：下周四（10-01，第 4 周）14:00 课 fire=13:50 > 窗口末 → 跳过
            let beyond = WidgetSnapshot.Course(
                id: 13, name: "下周课", teacher: "", location: "",
                dayOfWeek: 4, startPeriod: 3, duration: 1, color: 1, weekRule: [4]
            )
            #expect(build(Self.snapshot(courses: [beyond]), now: now, windowDays: 1).isEmpty)
        }

        @Test("weekRule 命中：不在该周的课跳过")
        func weekRuleFiltering() {
            let now = Self.date(2026, 9, 24, 10, 0)
            // 窗口内周一 = 09-28（第 4 周）与 10-05（第 5 周）：weekRule 只含第 6 周 → 无计划
            let odd = WidgetSnapshot.Course(
                id: 13, name: "单周课", teacher: "", location: "",
                dayOfWeek: 1, startPeriod: 1, duration: 1, color: 1, weekRule: [6]
            )
            #expect(build(Self.snapshot(courses: [odd]), now: now).isEmpty)
        }

        @Test("id 确定性：同输入两次构建 identifier 完全一致")
        func stableIdentifiers() {
            let now = Self.date(2026, 9, 24, 10, 0)
            let course = WidgetSnapshot.Course(
                id: 21, name: "英语", teacher: "李", location: "B202",
                dayOfWeek: 2, startPeriod: 2, duration: 1, color: 1, weekRule: [3, 4]
            )
            let a = build(Self.snapshot(courses: [course]), now: now)
            let b = build(Self.snapshot(courses: [course]), now: now)
            #expect(a.map(\.identifier) == b.map(\.identifier))
            #expect(a.count == 1) // 第 4 周周二 09-29 唯一命中（10-06 属第 5 周，weekRule 不含）
        }

        @Test("64 条截断保近端：候选超限 → 前 64 条按 fireDate 升序")
        func truncationKeepsNearest() {
            let now = Self.date(2026, 9, 24, 10, 0)
            // 26 门课 × 30 天窗口内同 weekday 重复 ≈ 130 条候选 > 64
            let courses = (0..<26).map { i in
                WidgetSnapshot.Course(
                    id: Int64(100 + i), name: "课\(i)", teacher: "", location: "",
                    dayOfWeek: i % 7 + 1, startPeriod: i % 3 + 1, duration: 1, color: 1,
                    weekRule: [1, 2, 3, 4, 5, 6, 7]
                )
            }
            let items = build(Self.snapshot(courses: courses), now: now, windowDays: 30)
            #expect(items.count == 64)
            let sorted = items.map(\.fireDate)
            #expect(sorted == sorted.sorted()) // 已按近端排序
            // 未截断的前 64 与截断结果一致（保近端而非随机）
            let unbounded = build(Self.snapshot(courses: courses), now: now, windowDays: 30, limit: 1000)
            #expect(unbounded.count > 64)
            #expect(items.map(\.identifier) == unbounded.prefix(64).map(\.identifier))
        }

        @Test("空字段省略：教室/教师为空时 body 对应段省略")
        func bodyOmitsEmptySegments() {
            let now = Self.date(2026, 9, 24, 10, 0)
            let course = WidgetSnapshot.Course(
                id: 31, name: "体育", teacher: "", location: "",
                dayOfWeek: 1, startPeriod: 1, duration: 1, color: 1, weekRule: [3, 4]
            )
            let items = build(Self.snapshot(courses: [course]), now: now)
            #expect(items[0].body == "体育 · 08:00-09:35")
        }
    }
}
