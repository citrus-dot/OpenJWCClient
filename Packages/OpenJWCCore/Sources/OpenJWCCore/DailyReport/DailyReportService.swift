import Foundation
import GRDB

/// 日报生成编排（对齐 Android `DailyReportRepository`）：Mutex 串行（actor）+ 状态机落库。
/// 逐批（8 条/批）LLM 摘要 → 多批合并（拼接 >48KB 跳过合并轮）→ COMPLETED；
/// COMPLETED 不可覆盖（DailyReportDao 防降级守卫）；阶段 7 的 BGTask 直接复用。
public actor DailyReportService {
    /// 单批资讯条数（对齐 Android BATCH_SIZE）。
    static let batchSize = 8
    /// 当日资讯上限（对齐 Android MAX_SOURCES）。
    static let maxSources = 100
    /// 合并轮拼接上限（对齐 Android）。
    private static let mergeThresholdBytes = 48 * 1024
    /// 失败原因保存上限（对齐 Android）。
    private static let maxErrorChars = 300

    private let reportDao: DailyReportDao
    private let noticeDao: NoticeDao
    private let makeLoop: @Sendable () -> AgentLoop

    public init(
        db: any DatabaseWriter,
        makeLoop: @escaping @Sendable () -> AgentLoop
    ) {
        self.reportDao = DailyReportDao(db: db)
        self.noticeDao = NoticeDao(db: db)
        self.makeLoop = makeLoop
    }

    /// 生成某日日报；返回该日最终记录。
    /// 已完成的直接返回；生成中重复触发抛出（调用方并发保护）。
    public func generate(day: String) async throws -> DailyReportRecord {
        guard Self.isValidDay(day) else {
            throw DailyReportError.invalidDay(day)
        }
        if let existing = try await reportDao.get(day: day),
           existing.status == DailyReportStatus.completed.rawValue {
            return existing
        }

        let ids = try await noticeDao.idsByDay(day: day)
        guard ids.count <= Self.maxSources else {
            let error = "当日资讯超过 \(Self.maxSources) 条，已停止生成"
            try await reportDao.save(
                day: day, status: DailyReportStatus.failed.rawValue,
                content: "", sourceCount: ids.count,
                error: String(error.prefix(Self.maxErrorChars)),
                updatedAt: nowMillis()
            )
            throw DailyReportError.tooManySources(ids.count)
        }

        try await reportDao.save(
            day: day, status: DailyReportStatus.running.rawValue,
            content: "", sourceCount: ids.count, error: nil, updatedAt: nowMillis()
        )

        // 空日：直接完成（对齐 Android）
        guard !ids.isEmpty else {
            let record = DailyReportRecord(
                day: day,
                status: DailyReportStatus.completed.rawValue,
                content: "当日没有已收录的资讯。",
                sourceCount: 0, error: nil, updatedAt: nowMillis()
            )
            try await reportDao.save(
                day: day, status: record.status, content: record.content,
                sourceCount: record.sourceCount, error: nil, updatedAt: record.updatedAt
            )
            return record
        }

        do {
            let batches = ids.count <= Self.batchSize
                ? [ids]
                : stride(from: 0, to: ids.count, by: Self.batchSize).map {
                    Array(ids[$0..<min($0 + Self.batchSize, ids.count)])
                }
            let loop = makeLoop()
            var parts: [String] = []
            for batch in batches {
                parts.append(try await loop.answer(AgentRequest(
                    query: PromptTemplates.dailyBatchQuery(day: day),
                    history: [],
                    noticeIds: batch
                )))
            }

            let content: String
            if parts.count == 1 {
                content = parts[0]
            } else {
                let joined = parts.joined(separator: "\n\n")
                if joined.utf8.count > Self.mergeThresholdBytes {
                    // 超过合并阈值：跳过合并轮，直接拼接返回（对齐 Android）
                    content = joined
                } else {
                    content = try await loop.answer(AgentRequest(
                        query: PromptTemplates.dailyMergeQuery(day: day, parts: joined),
                        history: [], noticeIds: []
                    ))
                }
            }

            try await reportDao.save(
                day: day, status: DailyReportStatus.completed.rawValue,
                content: content, sourceCount: ids.count,
                error: nil, updatedAt: nowMillis()
            )
            return DailyReportRecord(
                day: day, status: DailyReportStatus.completed.rawValue,
                content: content, sourceCount: ids.count,
                error: nil, updatedAt: nowMillis()
            )
        } catch is CancellationError {
            try await reportDao.save(
                day: day, status: DailyReportStatus.failed.rawValue,
                content: "", sourceCount: ids.count,
                error: "已取消", updatedAt: nowMillis()
            )
            throw CancellationError()
        } catch {
            let message = String((error.localizedDescription).prefix(Self.maxErrorChars))
            try await reportDao.save(
                day: day, status: DailyReportStatus.failed.rawValue,
                content: "", sourceCount: ids.count,
                error: message, updatedAt: nowMillis()
            )
            throw DailyReportError.generationFailed(message)
        }
    }

    /// 某日状态（无记录返回 nil）。
    public func statusOf(day: String) async throws -> String? {
        try await reportDao.get(day: day)?.status
    }

    private func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func isValidDay(_ day: String) -> Bool {
        let regex = "^\\d{4}-\\d{2}-\\d{2}$"
        return day.range(of: regex, options: .regularExpression) != nil
    }
}

public enum DailyReportError: Error, LocalizedError {
    case invalidDay(String)
    case tooManySources(Int)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDay(let day): return "日期格式不合法：\(day)（应为 yyyy-MM-dd）"
        case .tooManySources(let count): return "当日资讯超过 \(DailyReportService.maxSources) 条（实际 \(count)）"
        case .generationFailed(let message): return message
        }
    }
}
