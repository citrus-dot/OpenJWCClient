import Foundation
import BackgroundTasks
import OpenJWCCore

/// 后台任务协调器（design D-1/D-2，spec「后台资讯抓取/日报定时生成」Requirement）：
/// BGAppRefreshTask 资讯抓取 + BGProcessingTask 日报生成 + 前台 Timer 补充 + 日报前台补偿。
///
/// **红线 1（Swift 6 严格并发闭包隔离）**：`register` 的 launchHandler 与 `task.expirationHandler`
/// 由系统在**后台队列**调用；若闭包定义在 @MainActor 方法内会继承隔离 → 系统调用入口处
/// `EXC_BREAKPOINT`（早于 `Task { @MainActor in }` 执行，编译零警告）。因此两类闭包一律经
/// `nonisolated static` 上下文定义（`registerHandlers` / `setExpiration`），闭包内只做跳主线程
/// 一件事，不触碰任何 @MainActor 状态。
@MainActor
@Observable
final class BackgroundTaskCoordinator {
    /// 任务 id 常量（nonisolated：register/expiration 的 nonisolated static 上下文引用）
    nonisolated static let newsRefreshId = "org.openjwc.newsrefresh"
    nonisolated static let dailyReportId = "org.openjwc.dailyreport"

    /// 最近一次后台事件（调试/验收观测用）。
    private(set) var lastEvent = ""

    private let service: NewsCrawlService
    private let dailyReportService: DailyReportService
    private let dailyReportStore: DailyReportStore
    private let settings: SettingsStore
    private let sourceDao: SourceDao
    /// 课程提醒调度器（触发链直呼：课表变化 → reschedule）。
    let reminders: CourseReminderScheduler

    /// 前台 Timer 抓取任务（scenePhase active 期间按间隔驱动）。
    private var timerTask: Task<Void, Never>?
    /// 后台任务运行中的句柄（expiration 取消用）。
    private var newsJob: Task<Void, Never>?
    private var dailyJob: Task<Void, Never>?
    /// setTaskCompleted 恰好一次守卫。
    private var newsCompleted = false
    private var dailyCompleted = false

    init(
        service: NewsCrawlService,
        dailyReportService: DailyReportService,
        dailyReportStore: DailyReportStore,
        settings: SettingsStore,
        sourceDao: SourceDao,
        reminders: CourseReminderScheduler
    ) {
        self.service = service
        self.dailyReportService = dailyReportService
        self.dailyReportStore = dailyReportStore
        self.settings = settings
        self.sourceDao = sourceDao
        self.reminders = reminders
    }

    // MARK: - 注册（红线 1：闭包定义于 nonisolated static 上下文）

    /// App 启动完成前调用（OpenJWCApp.init）。BGTask 由系统传入，跨隔离传递以
    /// nonisolated(unsafe) 桥接（BGTask 未标 Sendable；系统保证单线程交付同一实例）。
    nonisolated static func registerHandlers(coordinator: BackgroundTaskCoordinator) {
        let scheduler = BGTaskScheduler.shared

        scheduler.register(forTaskWithIdentifier: newsRefreshId, using: nil) { task in
            nonisolated(unsafe) let bgTask = task
            Task { @MainActor in
                coordinator.handleNewsRefresh(bgTask as! BGAppRefreshTask)
            }
        }
        scheduler.register(forTaskWithIdentifier: dailyReportId, using: nil) { task in
            nonisolated(unsafe) let bgTask = task
            Task { @MainActor in
                coordinator.handleDailyReport(bgTask as! BGProcessingTask)
            }
        }
    }

    /// expirationHandler 同样由系统后台队列调用——nonisolated static 设置，闭包内只跳主线程。
    nonisolated static func setExpiration(
        for task: BGTask, coordinator: BackgroundTaskCoordinator
    ) {
        nonisolated(unsafe) let bgTask = task
        task.expirationHandler = {
            Task { @MainActor in
                coordinator.handleExpiration(of: bgTask)
            }
        }
    }

    // MARK: - 提交与取消（对齐 Android SourceCrawlScheduler / DailyReportScheduler.sync）

    /// 设置/订阅/课表变化与 scenePhase active 时的全量同步（对齐 MainActivity 五字段 → 三 sync）。
    func syncAll() async {
        await submitNewsTask()
        await submitDailyReportTask()
        await reminders.reschedule()
    }

    /// 资讯抓取任务：通知开启且有订阅源 → 提交（earliest = 检查间隔）；否则取消。
    func submitNewsTask() async {
        let userSettings = settings.loadUserSettings()
        guard userSettings.newsNotificationEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.newsRefreshId)
            return
        }
        let subscribed = (try? await sourceDao.getSubscribed()) ?? []
        guard !subscribed.isEmpty else {
            // 对齐 Android：无订阅源 → cancel
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.newsRefreshId)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.newsRefreshId)
        // 语义差异（spec 产品口径）：earliest 是最早时刻，系统按电量/使用习惯合并唤醒，不保证准点
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(userSettings.newsCheckIntervalMinutes * 60))
        do {
            try BGTaskScheduler.shared.submit(request)
            lastEvent = "newsRefresh submitted @\(Int(userSettings.newsCheckIntervalMinutes))min"
        } catch {
            // .notPermitted（用户关闭后台刷新）/.tooManyPendingTaskRequests/.unavailable（模拟器旧版）：
            // 静默吞并记日志，不崩溃不报错——前台 Timer + 启动抓取兜底
            lastEvent = "newsRefresh submit failed: \(error.localizedDescription)"
        }
    }

    /// 日报任务：开启 → 提交（earliest = 下一个 dailyReportTime）；关闭 → 取消。
    func submitDailyReportTask() async {
        let userSettings = settings.loadUserSettings()
        guard userSettings.dailyReportEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.dailyReportId)
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.dailyReportId)
        request.requiresNetworkConnectivity = true
        // 默认 true 会让「睡前充电才生成」变成硬约束，00:10 场景不成立（D-2）
        request.requiresExternalPower = false
        request.earliestBeginDate = Self.nextOccurrence(of: userSettings.dailyReportTime, from: Date())
        do {
            try BGTaskScheduler.shared.submit(request)
            lastEvent = "dailyReport submitted @\(userSettings.dailyReportTime)"
        } catch {
            lastEvent = "dailyReport submit failed: \(error.localizedDescription)"
        }
    }

    /// 下一个 HH:mm 时刻（已过今天该时刻 → 明天；解析失败 → 1 小时后，对齐 Android 退化）。
    static func nextOccurrence(of hhmm: String, from date: Date) -> Date {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else {
            return date.addingTimeInterval(3600)
        }
        var calendar = Calendar.current
        calendar.timeZone = .current
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = h
        comps.minute = m
        guard let today = calendar.date(from: comps) else {
            return date.addingTimeInterval(3600)
        }
        return today > date ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? date.addingTimeInterval(3600)
    }

    // MARK: - BGTask 运行体（所有路径恰好一次 setTaskCompleted）

    func handleNewsRefresh(_ task: BGAppRefreshTask) {
        lastEvent = "newsRefresh launched"
        newsCompleted = false
        Self.setExpiration(for: task, coordinator: self)
        newsJob = Task { [weak self] in
            guard let self else { return }
            var success = true
            do {
                try await self.runNewsFetch()
            } catch {
                success = false
                NSLog("BackgroundTask newsRefresh 失败: \(error)")
            }
            await self.submitNewsTask() // 续排：成功/失败/取消皆同（BGTask 无自动重试）
            self.finishNews(task, success: success)
        }
    }

    func handleDailyReport(_ task: BGProcessingTask) {
        lastEvent = "dailyReport launched"
        dailyCompleted = false
        Self.setExpiration(for: task, coordinator: self)
        dailyJob = Task { [weak self] in
            guard let self else { return }
            var success = true
            do {
                try await self.runDailyGeneration()
            } catch {
                // 配置类失败（缺 Key/Key 无效）不重试，原因已落库页面可见（对齐 Android CONFIG_RELATED）
                NSLog("BackgroundTask dailyReport 失败: \(error)")
            }
            await self.submitDailyReportTask() // 续排次日时刻
            self.finishDaily(task, success: success)
        }
    }

    /// expiration（系统即将挂起）：取消运行体 + 立即收尾（幂等）+ 续排。
    func handleExpiration(of task: BGTask) {
        lastEvent = "\(task.identifier) expired"
        switch task.identifier {
        case Self.newsRefreshId:
            newsJob?.cancel()
            finishNews(task as? BGAppRefreshTask, success: false)
        case Self.dailyReportId:
            dailyJob?.cancel()
            finishDaily(task as? BGProcessingTask, success: false)
        default:
            break
        }
    }

    private func finishNews(_ task: BGAppRefreshTask?, success: Bool) {
        guard !newsCompleted else { return }
        newsCompleted = true
        newsJob = nil
        task?.setTaskCompleted(success: success)
    }

    private func finishDaily(_ task: BGProcessingTask?, success: Bool) {
        guard !dailyCompleted else { return }
        dailyCompleted = true
        dailyJob = nil
        task?.setTaskCompleted(success: success)
    }

    /// 资讯抓取：全量抓取（共用防重入闸）→ 聚合 newNotices → 开关运行时判定 → 发通知。
    private func runNewsFetch() async throws {
        let userSettings = settings.loadUserSettings()
        let sources = try await sourceDao.getSubscribed()
        guard !sources.isEmpty else { return }
        var notices: [NoticeBrief] = []
        let stream = await service.crawl(sources: sources, crawlDaysGap: userSettings.crawlDaysGap)
        for await event in stream {
            if case .newNotices(_, let list) = event {
                notices.append(contentsOf: list)
            }
        }
        if userSettings.newsNotificationEnabled, !notices.isEmpty {
            await NewsNotifier.post(notices: notices)
        }
    }

    /// 日报生成：昨日（对齐 Android DailyReportWorker）；COMPLETED 幂等守卫在 service 层。
    private func runDailyGeneration() async throws {
        let yesterday = DailyReportStore.dayString(Date().addingTimeInterval(-86_400))
        _ = try await dailyReportService.generate(day: yesterday)
    }

    // MARK: - 前台补充（iOS 语义差异的核心替代）

    /// scenePhase active 期间启动应用内 Timer（按 newsCheckIntervalMinutes 间隔驱动抓取，
    /// 对齐 Android WorkManager 前台照跑语义；与后台任务共用 NewsCrawlService 防重入闸）。
    func startForegroundTimer() {
        stopForegroundTimer()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.settings.loadUserSettings().newsCheckIntervalMinutes ?? 60
                try? await Task.sleep(for: .seconds(TimeInterval(interval * 60)))
                guard !Task.isCancelled else { break }
                await self?.crawlOnce()
            }
        }
    }

    func stopForegroundTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// 前台静默抓取一次（Timer 与设置页「开启通知立即抓取」共用；不弹进度面板）。
    /// 防重入：service.isRunning 闸（后台任务/用户下拉在跑则本轮跳过）。
    func crawlOnce() async {
        let userSettings = settings.loadUserSettings()
        let sources = (try? await sourceDao.getSubscribed()) ?? []
        guard !sources.isEmpty else { return }
        guard await !service.running else { return }
        var notices: [NoticeBrief] = []
        let stream = await service.crawl(sources: sources, crawlDaysGap: userSettings.crawlDaysGap)
        for await event in stream {
            if case .newNotices(_, let list) = event {
                notices.append(contentsOf: list)
            }
        }
        if userSettings.newsNotificationEnabled, !notices.isEmpty {
            await NewsNotifier.post(notices: notices)
        }
    }

    // MARK: - 日报前台补偿（D-2：iOS 不保证准点后台执行的核心替代）

    /// bootstrap 调用：今日已过 dailyReportTime 且昨日日报非 COMPLETED → 前台补生成
    /// （进度在日报页可见；generate 的 COMPLETED 幂等守卫防重复）。
    func compensateDailyReportIfMissed() async {
        let userSettings = settings.loadUserSettings()
        guard userSettings.dailyReportEnabled else { return }
        // 今日已过 dailyReportTime 才需要补偿
        let parts = userSettings.dailyReportTime.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return }
        var calendar = Calendar.current
        calendar.timeZone = .current
        guard let todayAtTime = calendar.date(
            bySettingHour: h, minute: m, second: 0, of: Date()
        ), Date() >= todayAtTime else {
            return
        }
        let yesterday = DailyReportStore.dayString(Date().addingTimeInterval(-86_400))
        let status = (try? await dailyReportService.statusOf(day: yesterday)) ?? nil
        guard status != DailyReportStatus.completed.rawValue else { return }
        lastEvent = "dailyReport 前台补偿（昨日 \(status ?? "缺失")）"
        await dailyReportStore.generate()
    }
}
