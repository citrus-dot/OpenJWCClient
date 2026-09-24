import Testing
import Foundation
import CoreGraphics
import ImageIO
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

    // MARK: - 组 2.4 WidgetImageProcessor（红线 3）

    @Suite("WidgetImageProcessor 降采样")
    struct ImageProcessorTests {

        /// 画一张纯色大图并编码为 PNG（3000×2000）。
        private func makeLargeImagePNG(width: Int = 3000, height: Int = 2000) -> Data? {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output, "public.png" as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }

        @Test("降采样：长边 ≤1280、JPEG 完整、体积受控")
        func downsampleAndEncode() throws {
            let original = try #require(makeLargeImagePNG())
            let originalSize = try #require(WidgetImageProcessor.pixelSize(of: original))
            #expect(max(originalSize.width, originalSize.height) == 3000)

            let jpeg = try #require(WidgetImageProcessor.downsampleAndEncode(imageData: original))
            let newSize = try #require(WidgetImageProcessor.pixelSize(of: jpeg))
            #expect(max(newSize.width, newSize.height) <= 1280)
            // 等比缩放：3000×2000 → 1280×853 附近
            #expect(abs(Double(newSize.width) / Double(newSize.height) - 1.5) < 0.02)
            #expect(jpeg.count < 500_000) // 产物 ≤ 数百 KB（纯色图实际远小于此）
        }

        @Test("无法解码的数据返回 nil")
        func invalidDataReturnsNil() {
            #expect(WidgetImageProcessor.downsampleAndEncode(imageData: Data([0x00, 0x01, 0x02])) == nil)
            #expect(WidgetImageProcessor.pixelSize(of: Data("junk".utf8)) == nil)
        }
    }

    // MARK: - 组 4.3 WidgetDisplayState 六分支 + WidgetTimelineBuilder

    @Suite("WidgetDisplayState 显示状态")
    struct DisplayStateTests {

        private static let tz = TimeZone(identifier: "Asia/Shanghai")!

        private static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            return cal.date(from: DateComponents(
                timeZone: tz, year: y, month: mo, day: d, hour: h, minute: mi
            ))!
        }

        /// 2026-09-07 周一起；09-24（周四）为第 3 周；窗口内周四课 weekRule 3，下周一 09-28 为第 4 周。
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

        private static func course(
            id: Int64, day: Int, period: Int, duration: Int = 1, weeks: Set<Int> = [3, 4, 5]
        ) -> WidgetSnapshot.Course {
            WidgetSnapshot.Course(
                id: id, name: "课\(id)", teacher: "师\(id)", location: "教室\(id)",
                dayOfWeek: day, startPeriod: period, duration: duration,
                color: Int64(-id), weekRule: weeks
            )
        }

        private func compute(_ snapshot: WidgetSnapshot, at date: Date) -> WidgetDisplayState {
            WidgetDisplayState.compute(snapshot: snapshot, date: date, timeZone: Self.tz)
        }

        @Test("场景①今天剩余过滤：10:00 显示 10:00 与 14:00 两门，进行中显示约 95 分钟")
        func remainingFilter() {
            // 周四（dayOfWeek=4）三门：节 1、2、3
            let snapshot = Self.snapshot(courses: [
                Self.course(id: 1, day: 4, period: 1),
                Self.course(id: 2, day: 4, period: 2),
                Self.course(id: 3, day: 4, period: 3),
            ])
            let state = compute(snapshot, at: Self.date(2026, 9, 24, 10, 0)) // 第 3 周周四
            #expect(!state.showsTomorrow)
            #expect(state.emptyMessage == nil)
            #expect(state.courses.count == 2)
            #expect(state.courses[0].id == 2)
            #expect(state.courses[0].countdownMinutes == 95) // 11:35 - 10:00
            #expect(state.courses[1].id == 3)
            #expect(state.courses[1].countdownMinutes == nil) // 未开始无倒计时
        }

        @Test("场景②刚结束保留至下节开始：9:40 显示第一节倒计时 0 + 后续课；10:00 保留消失")
        func justEndedRetention() {
            let snapshot = Self.snapshot(courses: [
                Self.course(id: 1, day: 4, period: 1),
                Self.course(id: 2, day: 4, period: 2),
            ])
            // 9:40：第一节刚结束（9:35），下一节 10:00 未开始 → 保留倒计时 0
            let retained = compute(snapshot, at: Self.date(2026, 9, 24, 9, 40))
            #expect(retained.courses.map(\.id) == [1, 2])
            #expect(retained.courses[0].countdownMinutes == 0)
            #expect(retained.courses[1].countdownMinutes == nil)

            // 10:00 整：下节开始，第一节让位
            let shifted = compute(snapshot, at: Self.date(2026, 9, 24, 10, 0))
            #expect(shifted.courses.map(\.id) == [2])
        }

        @Test("场景③17:00 与末课后切明天：18:00 显示明天课程 + 明天周次")
        func switchToTomorrow() {
            // 周四课（第 3 周）+ 周五课（09-25 仍属第 3 周）
            let snapshot = Self.snapshot(courses: [
                Self.course(id: 1, day: 4, period: 1),
                Self.course(id: 2, day: 5, period: 2),
            ])
            let state = compute(snapshot, at: Self.date(2026, 9, 24, 18, 0))
            #expect(state.showsTomorrow)
            #expect(state.courses.map(\.id) == [2]) // 明天（周五）的课
            #expect(state.weekNumber == 3)
        }

        @Test("场景④明天无课显示「明天没有课」")
        func tomorrowEmpty() {
            // 周四课，周五（09-26 属第 3 周）无课 → 18:00 切明天显示「明天没有课」
            let snapshot = Self.snapshot(courses: [
                Self.course(id: 1, day: 4, period: 1),
            ])
            let state = compute(snapshot, at: Self.date(2026, 9, 24, 18, 0))
            #expect(state.showsTomorrow)
            #expect(state.courses.isEmpty)
            #expect(state.emptyMessage == "明天没有课")
            #expect(state.weekNumber == 3) // 明天 09-26 仍在第 3 周
        }

        @Test("场景⑤今天无课显示「今天没有课」")
        func todayEmpty() {
            let snapshot = Self.snapshot(courses: [
                Self.course(id: 1, day: 1, period: 1),
            ])
            let state = compute(snapshot, at: Self.date(2026, 9, 24, 10, 0)) // 周四无课
            #expect(!state.showsTomorrow)
            #expect(state.emptyMessage == "今天没有课")
        }

        @Test("场景⑥全部结束空态：末课结束且无保留可能（无有效节次）→「今日课程已结束」")
        func allCompleted() {
            // 末课（最后一门开始的课）结束后保留倒计时 0；要触达「今日课程已结束」
            // 需保留分支不可用（保留课为数据异常课：节次无法解析）
            let broken = WidgetSnapshot.Course(
                id: 9, name: "坏课", teacher: "", location: "",
                dayOfWeek: 4, startPeriod: 99, duration: 1, // 节 99 越界 → start/end 空
                color: 1, weekRule: [3]
            )
            let snapshot = Self.snapshot(courses: [broken])
            let state = compute(snapshot, at: Self.date(2026, 9, 24, 10, 0))
            #expect(!state.showsTomorrow)
            #expect(state.emptyMessage == "今日课程已结束")
        }

        @Test("倒计时 ceil 不为负 + MAX 2 截断 + 周次标注")
        func countdownAndTruncation() {
            // 4 门课：同时段只能显示 2 门
            let snapshot = Self.snapshot(courses: (1...4).map {
                Self.course(id: Int64($0), day: 4, period: 2)
            })
            let state = compute(snapshot, at: Self.date(2026, 9, 24, 10, 20))
            #expect(state.courses.count == WidgetDisplayState.maxCourses)
            #expect(state.courses[0].countdownMinutes == 75) // 11:35 - 10:20
            #expect(state.weekNumber == 3)
        }
    }

    @Suite("WidgetTimelineBuilder 时间线")
    struct TimelineBuilderTests {

        private static let tz = TimeZone(identifier: "Asia/Shanghai")!

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
                ],
                courses: courses
            )
        }

        @Test("节次边界 + 分钟倒计时 entry：进行中逐分钟推进")
        func boundaryAndMinuteEntries() {
            // 周四 10:00-11:35 一门课（第 3 周）
            let course = WidgetSnapshot.Course(
                id: 1, name: "课", teacher: "", location: "",
                dayOfWeek: 4, startPeriod: 2, duration: 1, color: 1, weekRule: [3]
            )
            let now = Self.date(2026, 9, 24, 10, 20)
            let entries = WidgetTimelineBuilder.build(
                snapshot: Self.snapshot(courses: [course]), date: now, timeZone: Self.tz
            )

            // 首 entry = 当前时刻
            #expect(entries.first?.date == now)
            // 76 分钟 entry（10:20..11:35 含两端）+ 今日/明日 forecast 切换点与 00:05 切日点 4 个 = 80
            #expect(entries.count == 80)
            // 单调递增
            let dates = entries.map(\.date)
            #expect(dates == dates.sorted())
            #expect(dates.first == now)
            // 倒计时推进：10:20 → 75 分钟；11:35 边界 entry → 0
            #expect(entries[0].state.courses.first?.countdownMinutes == 75)
            let endBoundary = entries.first { $0.date == Self.date(2026, 9, 24, 11, 35) }
            #expect(endBoundary?.state.courses.first?.countdownMinutes == 0)
        }

        @Test("午夜后 00:05 切日 entry 存在且状态切新一天")
        func dayRollEntry() {
            // 周四 18:00（已切明天预告）；时间线应含 09-27 00:05（周日凌晨）切日点
            let course = WidgetSnapshot.Course(
                id: 1, name: "课", teacher: "", location: "",
                dayOfWeek: 4, startPeriod: 1, duration: 1, color: 1, weekRule: [3]
            )
            let now = Self.date(2026, 9, 24, 18, 0)
            let entries = WidgetTimelineBuilder.build(
                snapshot: Self.snapshot(courses: [course]), date: now, timeZone: Self.tz
            )
            let rollDate = Self.date(2026, 9, 25, 0, 5) // 次日 00:05
            #expect(entries.contains { $0.date == rollDate })
            // 单调 + 全部 >= now
            #expect(entries.allSatisfy { $0.date >= now })
        }

        @Test("缺失快照回退空态单 entry")
        func missingSnapshotFallback() {
            let entries = WidgetTimelineBuilder.build(snapshot: nil, date: Self.date(2026, 9, 24, 10, 0), timeZone: Self.tz)
            #expect(entries.count == 1)
            #expect(entries[0].state.emptyMessage == "今天没有课")
            #expect(entries[0].state.courses.isEmpty)
        }
    }
}
