import SwiftUI

/// 五 tab 导航壳（顺序对齐 Android MainTab）。
/// iOS 26 玻璃语言就地采用（D-8）：TabView 系统样式自带 Liquid Glass；
/// 滚动收纳用 tabBarMinimizeBehavior，iOS 18 回退默认样式。
struct AppShellView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

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

            PlaceholderTabView(title: "课程表", systemImage: "tablecells", phase: 7)
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
