import SwiftUI
import UserNotifications

@main
struct OpenJWCApp: App {
    private let environment: AppEnvironment
    @State private var router = AppRouter()
    @State private var delegate = NotificationDelegate()

    init() {
        do {
            environment = try AppEnvironment()
        } catch {
            // 数据库不可用属致命错误：无库则全部功能失效
            fatalError("数据库初始化失败: \(error)")
        }
        UNUserNotificationCenter.current().delegate = delegate
    }

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environment(environment)
                .environment(environment.reactive)
                .environment(environment.news)
                .environment(environment.crawl)
                .environment(environment.chat)
                .environment(environment.dailyReport)
                .environment(environment.motto)
                .environment(router)
                .task { await environment.bootstrap() }
                .task {
                    // D-6 冷/热启动一致：点击通知 → DeepLink 流 → 路由队列 → 首帧后消费
                    for await link in delegate.links {
                        router.enqueueDeepLink(link)
                    }
                }
        }
    }
}

/// 通知响应桥（D-6）：点击通知 → 提取 userInfo 键为 Sendable 的 DeepLink → 流给路由层。
/// 阶段 7 前仅消费不注册（深链手验用 NewsListView 的调试入口排期测试通知）。
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    let links: AsyncStream<DeepLink>
    private let continuation: AsyncStream<DeepLink>.Continuation

    override init() {
        (links, continuation) = AsyncStream.makeStream(
            of: DeepLink.self, bufferingPolicy: .unbounded
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        continuation.yield(DeepLink(
            destination: info["destination"] as? String,
            newsId: info["news_id"] as? String
        ))
        completionHandler()
    }

    /// 前台同样显示横幅：iOS 默认前台静默丢弃通知，深链调试入口触发时 App 正在前台，
    /// 不加此回调则横幅永远不出现（点不了也就无法验证点击深链）。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
