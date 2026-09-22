import Foundation
import Testing
import GRDB
@testable import OpenJWCCore

/// DailyReportService 测试（tasks 2.6）：空日直完成 / 分批 / >100 拒绝 / COMPLETED 防覆盖 / 失败落库。
@Suite("DailyReportService 生成编排")
struct DailyReportServiceTests {

    private func makeTempDB() throws -> DatabaseProvider {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openjwc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DatabaseProvider(databasePath: dir.appendingPathComponent("test.sqlite").path)
    }

    /// 预置某日的 N 条资讯。
    private func seedNotices(_ db: DatabaseProvider, day: String, count: Int) async throws {
        let dao = NoticeDao(db: db.dbWriter)
        let base = Int64(day.replacingOccurrences(of: "-", with: "")) ?? 0
        let records = (0..<count).map { i in
            NoticeRecord(
                id: "n-\(day)-\(i)", sourceId: "s", label: "通知",
                title: "第\(i)条", publishedAt: base * 1000 + Int64(i),
                publishedDay: day, detailUrl: "https://x/\(i)", isPage: true,
                content: "正文\(i)", contentVersion: 1, attachments: nil,
                fetchedAt: 1, notified: false, favorite: false
            )
        }
        try await dao.upsertAll(records)
    }

    private func makeService(
        _ db: DatabaseProvider,
        rounds: [[LlmDelta]],
        callCounter: CallCounter? = nil
    ) -> DailyReportService {
        DailyReportService(db: db.dbWriter) {
            let client = CountingClient(rounds: rounds, counter: callCounter)
            return AgentLoop(
                client: client,
                tools: AgentTools(repository: FakeCorpus()),
                repository: FakeCorpus()
            )
        }
    }

    /// 调用计数器（跨 @Sendable 闭包共享）。
    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// 计数 + 按调用序取轮的假客户端。
    final class CountingClient: LlmClient, @unchecked Sendable {
        let config = LlmProviderConfig()
        private let rounds: [[LlmDelta]]
        private let counter: CallCounter?
        private let lock = NSLock()
        private var calls = 0

        init(rounds: [[LlmDelta]], counter: CallCounter?) {
            self.rounds = rounds
            self.counter = counter
        }

        func streamChat(messages: [LlmMessage], tools: [LlmToolSpec]) -> AsyncThrowingStream<LlmDelta, Error> {
            lock.lock()
            let index = min(calls, rounds.count - 1)
            calls += 1
            lock.unlock()
            counter?.increment()
            let deltas = rounds[index]
            return AsyncThrowingStream { continuation in
                for delta in deltas { continuation.yield(delta) }
                continuation.finish()
            }
        }
    }

    @Test("日期格式校验：非 yyyy-MM-dd 拒绝")
    func invalidDayRejected() async throws {
        let db = try makeTempDB()
        let service = makeService(db, rounds: [])
        await #expect(throws: DailyReportError.self) {
            try await service.generate(day: "2026/09/21")
        }
    }

    @Test("空日：直接完成态「当日没有已收录的资讯。」")
    func emptyDayCompletes() async throws {
        let db = try makeTempDB()
        let service = makeService(db, rounds: [])
        let record = try await service.generate(day: "2026-09-21")
        #expect(record.status == "completed")
        #expect(record.content == "当日没有已收录的资讯。")
        #expect(record.sourceCount == 0)
    }

    @Test("9 条资讯 → 2 批；每批 answer = 工具轮+收束 2 次调用，合并轮再 2 次（共 6 次）")
    func batchingAndMerge() async throws {
        let db = try makeTempDB()
        let day = "2026-09-20"
        try await seedNotices(db, day: day, count: 9)
        let counter = CallCounter()
        // 批1(round+finalize)、批2(round+finalize)、合并(round+finalize)
        let service = makeService(db, rounds: [
            [.text("批1"), .finished("stop")],
            [.text("批1摘要"), .finished("stop")],
            [.text("批2"), .finished("stop")],
            [.text("批2摘要"), .finished("stop")],
            [.text("合并"), .finished("stop")],
            [.text("合并后日报"), .finished("stop")],
        ], callCounter: counter)

        let record = try await service.generate(day: day)
        #expect(record.status == "completed")
        #expect(record.content == "合并后日报")
        #expect(record.sourceCount == 9)
        #expect(counter.value == 6)
    }

    @Test("单批（≤8 条）不触发合并轮（round+finalize 共 2 次调用）")
    func singleBatchNoMerge() async throws {
        let db = try makeTempDB()
        let day = "2026-09-19"
        try await seedNotices(db, day: day, count: 5)
        let counter = CallCounter()
        let service = makeService(db, rounds: [
            [.text("单批"), .finished("stop")],
            [.text("单批日报"), .finished("stop")],
        ], callCounter: counter)

        let record = try await service.generate(day: day)
        #expect(record.content == "单批日报")
        #expect(counter.value == 2)
    }

    @Test("拼接 >48KB 跳过合并轮（3 批 × 20KB 拼接）")
    func mergeSkippedWhenTooLarge() async throws {
        let db = try makeTempDB()
        let day = "2026-09-18"
        try await seedNotices(db, day: day, count: 17) // 3 批
        let big = String(repeating: "字", count: 20_000) // 每批约 60KB UTF-8
        let counter = CallCounter()
        let service = makeService(db, rounds: [
            [.text(big), .finished("stop")],
            [.text(big), .finished("stop")],
            [.text(big), .finished("stop")],
        ], callCounter: counter)

        let record = try await service.generate(day: day)
        #expect(record.status == "completed")
        // 3 批 × (round+finalize) = 6 次；拼接 180KB > 48KB → 不再调合并轮
        #expect(counter.value == 6)
        #expect(record.content.contains("字"))
    }

    @Test("超过 100 条：失败落库并抛错")
    func tooManySourcesRejected() async throws {
        let db = try makeTempDB()
        let day = "2026-09-17"
        try await seedNotices(db, day: day, count: 101)
        let service = makeService(db, rounds: [])
        await #expect(throws: DailyReportError.self) {
            try await service.generate(day: day)
        }
        let dao = DailyReportDao(db: db.dbWriter)
        let record = try #require(try await dao.get(day: day))
        #expect(record.status == "failed")
        #expect(record.error?.contains("100") == true)
    }

    @Test("COMPLETED 不可覆盖：已完成直接返回，不再调 LLM")
    func completedNotOverwritten() async throws {
        let db = try makeTempDB()
        let day = "2026-09-16"
        let dao = DailyReportDao(db: db.dbWriter)
        try await dao.save(
            day: day, status: "completed", content: "已有日报",
            sourceCount: 3, error: nil, updatedAt: 1
        )
        let counter = CallCounter()
        let service = makeService(db, rounds: [
            [.text("不该出现"), .finished("stop")],
        ], callCounter: counter)

        let record = try await service.generate(day: day)
        #expect(record.content == "已有日报")
        #expect(counter.value == 0)
    }

    @Test("LLM 失败：FAILED 落库含错误（≤300 字）")
    func failurePersists() async throws {
        let db = try makeTempDB()
        let day = "2026-09-15"
        try await seedNotices(db, day: day, count: 2)
        // 配置异常路径：makeLoop 返回缺 Key 的客户端 → AgentLoop 产 runFailed(configuration)
        let service = DailyReportService(db: db.dbWriter) {
            AgentLoop(
                client: OpenAiCompatibleClient(config: LlmProviderConfig(), apiKey: ""),
                tools: AgentTools(repository: FakeCorpus()),
                repository: FakeCorpus()
            )
        }
        await #expect(throws: DailyReportError.self) {
            try await service.generate(day: day)
        }
        let dao = DailyReportDao(db: db.dbWriter)
        let record = try #require(try await dao.get(day: day))
        #expect(record.status == "failed")
        #expect(record.error != nil)
        #expect(record.error?.count ?? 0 <= 300)
    }
}
