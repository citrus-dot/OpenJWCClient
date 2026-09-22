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

            PlaceholderTabView(title: "日报", systemImage: "doc.text", phase: 6)
                .tabItem { Label("日报", systemImage: "doc.text") }
                .tag(AppTab.dailyReport)

            NewsRootView()
                .tabItem { Label("资讯", systemImage: "newspaper") }
                .tag(AppTab.news)

            PlaceholderTabView(title: "课程表", systemImage: "tablecells", phase: 7)
                .tabItem { Label("课程表", systemImage: "tablecells") }
                .tag(AppTab.timetable)

            MePlaceholderView()
                .tabItem { Label("我的", systemImage: "person") }
                .tag(AppTab.me)
        }
        .tabBarMinimizeBehaviorIfAvailable()
        // D-6：深链动作在首帧渲染后执行（NavigationStack 已挂载），冷/热启动一致
        .task(id: router.pendingDeepLink) {
            guard let link = router.pendingDeepLink else { return }
            router.handleDeepLink(link)
        }
    }
}

/// D-8：iOS 26 起启用 tab bar 滚动收纳玻璃动效；低版本为 no-op。
extension View {
    @ViewBuilder
    func tabBarMinimizeBehaviorIfAvailable() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
