import Foundation

/// 顶层 tab，顺序对齐 Android `MainTab`。
enum AppTab: Hashable {
    case chat, dailyReport, news, timetable, me
}

/// 深链载荷（userInfo 解析结果，Equatable 便于 SwiftUI .task(id:) 观察）。
struct DeepLink: Equatable {
    var destination: String?
    var newsId: String?
}

/// D-6 路由状态：tab 选择 + 资讯详情栈 + 图片查看器 + 深链。
/// 深链动作统一在首帧渲染后由 AppShellView 消费（避免 NavigationStack 未挂载丢失）。
@Observable
final class AppRouter {
    /// 深链 destination 值（对齐 Android NotificationNavigation）。
    static let destNewsDetail = "news_detail"
    static let destNews = "news"
    static let destTimetable = "timetable"

    /// 场景「启动落在资讯 tab」：默认选中 News。
    var selectedTab: AppTab = .news

    /// 资讯详情栈（元素为 notice id）。
    var newsPath: [String] = []
    /// 收藏页是否压栈。
    var favoritesPresented = false
    /// 全屏图片查看器当前 URL；nil = 关闭。
    var viewerImageURL: String?
    /// 深链待开的详情 id；NewsRootView 校验后消费（无效 id 降级）。
    var pendingDetailId: String?

    /// 待消费的深链（冷/热启动一致），AppShellView 首帧后调 handleDeepLink。
    private(set) var pendingDeepLink: DeepLink?

    func enqueueDeepLink(_ link: DeepLink) {
        pendingDeepLink = link
    }

    /// D-6：userInfo 键沿用 Android extras 语义（destination / news_id）。
    /// 场景「点单条资讯通知」与「无效 id 降级」：news_detail 切 tab + 记待开 id（合法性由视图层查库判定）。
    func handleDeepLink(_ link: DeepLink) {
        pendingDeepLink = nil
        switch link.destination {
        case Self.destNewsDetail:
            selectedTab = .news
            pendingDetailId = link.newsId
        case Self.destNews:
            selectedTab = .news
        case Self.destTimetable:
            selectedTab = .timetable
        default:
            break
        }
    }
}
