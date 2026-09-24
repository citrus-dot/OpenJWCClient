import Foundation
import GRDB

/// 新资讯摘要（通知载荷最小面，D-5 扩展点）：仅通知构造所需字段。
public struct NoticeBrief: Equatable, Sendable {
    public var id: String
    public var title: String
    public var label: String

    public init(id: String, title: String, label: String) {
        self.id = id
        self.title = title
        self.label = label
    }
}

/// 抓取进度事件（对齐 Android NewsViewModel.CrawlProgress 的信息面）。
public enum CrawlEvent: Sendable {
    case started(total: Int)
    case sourceStarted(sourceId: String, sourceName: String, index: Int, total: Int)
    case sourceLog(sourceId: String, line: String)
    case sourceProgress(sourceId: String, fraction: Double, detail: String)
    case sourceFinished(sourceId: String, sourceName: String, summary: String, success: Bool)
    /// 新资讯外传（D-5）：非 baseline 且有新增条目时逐源 yield；水位语义不变。
    /// 前台交互抓取的消费者忽略此事件（「视为已读」），后台任务消费者聚合后发通知。
    case newNotices(sourceId: String, notices: [NoticeBrief])
    /// 全部源处理完毕或被取消；被取消时剩余源不再抓取，已落库结果保留。
    case finished(cancelled: Bool)
}

/// 抓取编排服务（对齐 Android `SourceRunner`）：逐订阅源执行脚本流程（fetchList→fetchContent），
/// 资讯经 NoticeDao 落库（含补抓判定与内容版本），完成后回写源运行结果。
///
/// 线程模型（D-4）：actor + `AsyncStream<CrawlEvent>`；每源复用 `JavaScriptHost` 的 worker
/// 竞速设计。取消 = `Task.cancel()` 在源间检查点生效（脚本执行中不可中断，与 Android 一致）；
/// 防重入 = actor 内 `isRunning` 状态位（重复调用返回立即结束的空流）。
public actor NewsCrawlService {
    /// 单源脚本超时（对齐 Android DEFAULT_TIMEOUT_MS）。
    public static let defaultTimeoutMs = 240_000
    /// 单次脚本允许的 HTTP 次数（翻页 + 正文，含首轮回溯）。
    private static let maxHttpCalls = 600
    /// 单次脚本允许下载的字节上限。
    private static let maxBytes = 32 * 1024 * 1024
    /// 运行结果（含警告样本）的保存上限。
    private static let maxWarningChars = 2000
    /// 写入正文时的格式版本（对齐 Android NOTICE_CONTENT_VERSION）。
    private static let noticeContentVersion = 1

    private let noticeDao: NoticeDao
    private let sourceDao: SourceDao
    private let host: JavaScriptHost
    /// 脚本来源：按源取脚本全文（app 侧注入 Bundle 资产读取，测试注入假脚本）。
    private let scriptProvider: @Sendable (NoticeSourceRecord) throws -> String

    private var isRunning = false

    public init(
        db: any DatabaseWriter,
        host: JavaScriptHost = JavaScriptHost(),
        scriptProvider: @escaping @Sendable (NoticeSourceRecord) throws -> String
    ) {
        self.noticeDao = NoticeDao(db: db)
        self.sourceDao = SourceDao(db: db)
        self.host = host
        self.scriptProvider = scriptProvider
    }

    /// 逐源抓取。防重入：已在抓取时返回立即结束的空流。
    /// 取消：消费方 Task 取消或对流调用 cancel，当前源跑完后剩余源不再抓取。
    public func crawl(
        sources: [NoticeSourceRecord],
        crawlDaysGap: Int,
        timeoutMs: Int = NewsCrawlService.defaultTimeoutMs
    ) -> AsyncStream<CrawlEvent> {
        guard !isRunning else {
            return AsyncStream { $0.finish() }
        }
        isRunning = true

        return AsyncStream(CrawlEvent.self, bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached { [weak self] in
                guard let self else { return }
                var cancelled = false
                await continuation.yield(.started(total: sources.count))

                for (index, source) in sources.enumerated() {
                    if Task.isCancelled { cancelled = true; break }
                    await continuation.yield(
                        .sourceStarted(sourceId: source.id, sourceName: source.name,
                                       index: index, total: sources.count)
                    )
                    let outcome = await self.crawlOne(source, crawlDaysGap: crawlDaysGap, timeoutMs: timeoutMs) {
                        continuation.yield($0)
                    }
                    await continuation.yield(.sourceFinished(
                        sourceId: source.id, sourceName: source.name,
                        summary: outcome.summary, success: outcome.success
                    ))
                }

                await continuation.yield(.finished(cancelled: cancelled))
                continuation.finish()
                await self.finishRun()
            }
            // 消费侧终止（放弃流/任务取消）→ 取消内部循环
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 抓取循环结束（成功/失败/取消皆同）：释放防重入位。
    private func finishRun() {
        isRunning = false
    }

    /// 是否正在抓取（UI 侧禁用刷新入口用；读取本身也是防重入的第二道闸）。
    public var running: Bool { isRunning }

    // MARK: - 单源抓取（对齐 SourceRunner.crawl）

    struct SingleOutcome {
        var success: Bool
        var summary: String
    }

    private func crawlOne(
        _ source: NoticeSourceRecord,
        crawlDaysGap: Int,
        timeoutMs: Int,
        yield: @escaping @Sendable (CrawlEvent) -> Void
    ) async -> SingleOutcome {
        do {
            let script = try scriptProvider(source)
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ScriptError.execution("脚本内容为空")
            }

            // 只把「已有当前格式正文」的条目视为已知：正文缺失或格式过旧的会在下次运行重抓
            let existingIds = try await noticeDao.idsBySource(sourceId: source.id)
            let knownIds = try await noticeDao.idsWithContentBySource(
                sourceId: source.id, minVersion: Self.noticeContentVersion
            )
            let sandbox = ScriptSandbox(
                allowedDomains: Set(source.domains.value),
                timeoutMs: timeoutMs,
                maxHttpCalls: Self.maxHttpCalls,
                maxBytes: Self.maxBytes
            )
            let outcome = try await host.run(
                script: script,
                sandbox: sandbox,
                params: ScriptRunParams(crawlDaysGap: crawlDaysGap, knownIds: knownIds),
                onLog: { line in
                    yield(.sourceLog(sourceId: source.id, line: line))
                },
                onProgress: { fraction, detail in
                    yield(.sourceProgress(sourceId: source.id, fraction: fraction, detail: detail))
                }
            )

            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let records = outcome.notices.map {
                Self.toRecord($0, sourceId: source.id, fetchedAt: now)
            }
            let newIds = Set(records.map(\.id)).subtracting(existingIds)
            let baseline = existingIds.isEmpty

            // upsert 整行覆盖：先记下用户态，写完再补回（顺序对齐 Android）
            let favoriteIds = try await noticeDao.selectFavoriteIds(ids: records.map(\.id))
            let notifiedIds = try await noticeDao.selectNotifiedIds(ids: records.map(\.id))
            try await noticeDao.upsertAll(records)
            if !favoriteIds.isEmpty { try await noticeDao.markFavorites(ids: favoriteIds) }
            if !notifiedIds.isEmpty { try await noticeDao.markNotified(ids: notifiedIds) }

            // 通知水位（对齐 settleNotifications，notify=false：交互抓取视为已读）；
            // 非 baseline 且有新增时顺带外传新资讯摘要（D-5 扩展点，水位语义不变）
            if baseline {
                try await noticeDao.markNotified(ids: records.map(\.id))
            } else if !newIds.isEmpty {
                try await noticeDao.markNotified(ids: Array(newIds))
                let briefs = records
                    .filter { newIds.contains($0.id) }
                    .map { NoticeBrief(id: $0.id, title: $0.title, label: $0.label) }
                yield(.newNotices(sourceId: source.id, notices: briefs))
            }

            // 非致命问题照常入库，把摘要写进运行结果；失败源同样回写（对齐 Android catch 分支之外的成功路径）
            let warning = Self.buildWarning(outcome)
            try await sourceDao.updateResult(id: source.id, timestamp: now, count: records.count, error: warning)

            let summary = Self.summarize(
                newCount: newIds.count, noContent: outcome.noContent,
                failed: outcome.failed, error: nil
            )
            return SingleOutcome(success: true, summary: summary)
        } catch {
            let message: String
            if error is ScriptError, let scriptError = error as? ScriptError {
                message = scriptError.description
            } else if error is CancellationError {
                message = "已取消"
            } else {
                message = error.localizedDescription
            }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            // 失败同样回写运行结果（count=0 + error），对齐 Android SourceRunner
            try? await sourceDao.updateResult(id: source.id, timestamp: now, count: 0, error: message)
            return SingleOutcome(success: false, summary: message)
        }
    }

    // MARK: - 归一化（对齐 Android FetchedNotice.toNoticeEntity）

    static func toRecord(
        _ notice: ScriptNotice, sourceId: String, fetchedAt: Int64
    ) -> NoticeRecord {
        let date = notice.date
        return NoticeRecord(
            id: notice.id.isEmpty ? notice.detailUrl : notice.id,
            sourceId: sourceId,
            label: notice.label.isEmpty ? "资讯" : notice.label,
            title: notice.title,
            publishedAt: parseDateSortKey(date),
            publishedDay: String(date.prefix(10)),
            detailUrl: notice.detailUrl,
            isPage: notice.isPage,
            content: notice.contentText,
            contentVersion: noticeContentVersion,
            attachments: notice.attachments.map(JSONStringList.init),
            fetchedAt: fetchedAt,
            notified: false,
            favorite: false
        )
    }

    /// 解析资讯日期字符串为排序键（epoch 毫秒），无法解析时返回 0。
    /// formatter 集合对齐 Android NEWS_DATE_FORMATTERS。
    static func parseDateSortKey(_ date: String) -> Int64 {
        let trimmed = date.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            if let parsed = formatter.date(from: trimmed) {
                return Int64(parsed.timeIntervalSince1970 * 1000)
            }
        }
        return 0
    }

    // MARK: - 文案（逐字对齐 Android buildWarning / summarizeCrawl）

    static func buildWarning(_ outcome: ScriptOutcome) -> String? {
        var lines: [String] = []
        if outcome.failed > 0 || outcome.noContent > 0 || outcome.skipped > 0 {
            var line = "扫描 \(outcome.scanned) 条，跳过 \(outcome.skipped) 条" +
                "（超出回溯窗口 \(outcome.skippedOld)、重复 \(outcome.skippedDuplicate)、" +
                "已入库 \(outcome.skippedKnown)），入库 \(outcome.notices.count) 条"
            if outcome.noContent > 0 {
                line += "，其中无正文 \(outcome.noContent) 条"
                if outcome.restricted > 0 {
                    line += "（仅校内 \(outcome.restricted) 条）"
                }
            }
            if outcome.failed > 0 {
                line += "，失败 \(outcome.failed) 条"
            }
            lines.append(line)
        }
        lines.append(contentsOf: outcome.warnings.map { "· \($0)" })
        guard !lines.isEmpty else { return nil }
        return String(lines.joined(separator: "\n").prefix(maxWarningChars))
    }

    static func summarize(
        newCount: Int, noContent: Int, failed: Int, error: String?
    ) -> String {
        var text = "新增 \(newCount) 条"
        if noContent > 0 { text += "，无正文 \(noContent) 条" }
        if failed > 0 { text += "，失败 \(failed) 条" }
        if let error { text += "，失败：\(error)" }
        return text
    }
}
