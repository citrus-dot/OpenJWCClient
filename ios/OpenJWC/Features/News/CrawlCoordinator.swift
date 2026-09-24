import Foundation
import OpenJWCCore

/// 抓取事件流 → UI 状态（对齐 Android NewsViewModel.CrawlProgress）。
/// 防重入双保险：这里 task 非空即拒绝，NewsCrawlService 内部 isRunning 第二道闸。
@MainActor
@Observable
final class CrawlCoordinator {
    struct Progress: Equatable {
        var running = false
        var total = 0
        var finished = 0
        var currentSourceName: String?
        /// 当前源内部进度 0..1（脚本上报）。
        var currentFraction: Double = 0
        var results: [String] = []
        /// 最近 200 行日志（对齐 Android MAX_CRAWL_LOGS）。
        var logs: [String] = []
    }

    private static let maxLogs = 200

    private(set) var progress = Progress()
    /// 进度面板呈现状态（全局 sheet；发起抓取自动弹，资讯页工具栏可随时重开）。
    var panelPresented = false

    private let service: NewsCrawlService
    private var task: Task<Void, Never>?

    init(service: NewsCrawlService) {
        self.service = service
    }

    /// 场景「防重入」：抓取中重复触发直接忽略。发起即弹出进度面板（全局可见）。
    func startCrawl(sources: [NoticeSourceRecord], crawlDaysGap: Int) {
        guard task == nil, !progress.running, !sources.isEmpty else { return }
        progress = Progress(running: true, total: sources.count)
        panelPresented = true

        task = Task { [weak self] in
            let stream = await self?.service.crawl(sources: sources, crawlDaysGap: crawlDaysGap)
            for await event in stream ?? AsyncStream { $0.finish() } {
                self?.apply(event)
            }
            self?.task = nil
        }
    }

    /// 场景「用户取消」：剩余源不再抓取，已落库结果保留。
    func cancelCrawl() {
        task?.cancel()
        task = nil
    }

    /// 等待当前抓取结束（refreshable 用；取消不影响其完成）。
    func awaitCompletion() async {
        let current = task
        await current?.value
    }

    private func apply(_ event: CrawlEvent) {
        switch event {
        case .started(let total):
            progress.total = total
        case .sourceStarted(_, let name, _, _):
            progress.currentSourceName = name
            progress.currentFraction = 0
            progress.logs.append("▶ \(name)")
            trimLogs()
        case .sourceLog(_, let line):
            progress.logs.append(line)
            trimLogs()
        case .sourceProgress(_, let fraction, _):
            progress.currentFraction = fraction
        case .sourceFinished(_, _, let summary, let success):
            progress.finished += 1
            progress.currentSourceName = nil
            progress.currentFraction = 0
            progress.results.append(success ? summary : "失败：\(summary)")
        case .newNotices:
            // D-5：前台交互抓取「视为已读」——新资讯事件仅由后台任务消费者消费，此处忽略
            break
        case .finished:
            progress.running = false
            progress.currentSourceName = nil
        }
    }

    private func trimLogs() {
        if progress.logs.count > Self.maxLogs {
            progress.logs.removeFirst(progress.logs.count - Self.maxLogs)
        }
    }
}
