import SwiftUI

/// 五 tab 导航壳（顺序对齐 Android MainTab）。
/// iOS 26 玻璃语言就地采用（D-8）：TabView 系统样式自带 Liquid Glass；
/// 滚动收纳用 tabBarMinimizeBehavior，iOS 18 回退默认样式。
struct AppShellView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            ChatRootView()
                .tabItem { Label("对话", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(AppTab.chat)

            DailyReportRootView()
                .tabItem { Label("日报", systemImage: "doc.text") }
                .tag(AppTab.dailyReport)

            NewsRootView()
                .tabItem { Label("资讯", systemImage: "newspaper") }
                .tag(AppTab.news)

            TimetableRootView()
                .tabItem { Label("课程表", systemImage: "tablecells") }
                .tag(AppTab.timetable)

            MeView()
                .tabItem { Label("我的", systemImage: "person") }
                .tag(AppTab.me)
        }
        // tab bar 滚动收纳：仅对话页关闭（聊天有底部输入栏 + 自动滚动，收纳造成跳动），
        // 其它 tab 保持 iOS 26 收纳行为；切 tab 时动态切换参数
        .tabBarMinimizeBehaviorIfAvailable(minimized: router.selectedTab != .chat)
        // 抓取进度面板：全局呈现（发起抓取自动弹；资讯页工具栏可随时重开）
        .sheet(isPresented: Binding(
            get: { environment.crawl.panelPresented },
            set: { environment.crawl.panelPresented = $0 }
        )) {
            CrawlProgressPanel()
                .presentationDetents([.medium, .large])
        }
        // D-6：深链动作在首帧渲染后执行（NavigationStack 已挂载），冷/热启动一致
        .task(id: router.pendingDeepLink) {
            guard let link = router.pendingDeepLink else { return }
            router.handleDeepLink(link)
        }
        // 阶段 7a 触发链（D-8 等价表）：前台提交/续排 + Timer 启停
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    await environment.backgroundTasks.syncAll()
                    environment.backgroundTasks.startForegroundTimer()
                }
            case .background, .inactive:
                environment.backgroundTasks.stopForegroundTimer()
            @unknown default:
                break
            }
        }
        // 订阅集合变化 → 抓取任务重排（对齐 NavContainer 订阅链）
        .onChange(of: environment.reactive.sources) { _, _ in
            Task { await environment.backgroundTasks.submitNewsTask() }
        }
        // 当前表/课程变化 → 课程提醒全量重排 + 小组件快照导出（对齐 NavContainer (table.id, courses.size) 链）
        .onChange(of: environment.timetable.snapshot) { _, _ in
            Task {
                await WidgetSnapshotWriter.export(db: environment.db)
                await environment.backgroundTasks.reminders.reschedule()
            }
        }
        // 小组件 widgetURL 深链（openjwc://timetable → 课表 tab）
        .onOpenURL { url in
            guard url.scheme == "openjwc" else { return }
            switch url.host {
            case "timetable":
                router.handleDeepLink(DeepLink(destination: AppRouter.destTimetable, newsId: nil))
            default:
                break
            }
        }
    }
}

/// D-8：iOS 26 起 tab bar 滚动收纳玻璃动效；minimized=false 的 tab 不触发。低版本 no-op。
extension View {
    @ViewBuilder
    func tabBarMinimizeBehaviorIfAvailable(minimized: Bool) -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(minimized ? .onScrollDown : .never)
        } else {
            self
        }
    }
}
