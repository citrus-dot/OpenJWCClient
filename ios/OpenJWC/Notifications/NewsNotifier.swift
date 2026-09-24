import Foundation
import UserNotifications
import OpenJWCCore

/// 新闻通知（design D-5，spec「新闻通知」Requirement）：
/// 单条 → title「新资讯」/ body 资讯标题 / 点击直达详情（destination=news_detail + news_id）；
/// 多条 → title「有新资讯」/ body「N 条新资讯」+ 首条标题 / 点击进列表（destination=news）。
/// 偏差记录：Android InboxStyle 逐行摘要与固定 id 1001 覆盖式在 iOS 无等价 API——
/// 替代为计数摘要 + threadIdentifier 系统堆叠 + 前缀时间戳 id（保留未读历史）。
enum NewsNotifier {
    static let threadIdentifier = "news"

    /// 发送前由调用方判定通知开关与权限（对齐 Android settleNotifications(notify:) 运行时判定）。
    static func post(notices: [NoticeBrief]) async {
        guard !notices.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        if notices.count == 1 {
            let notice = notices[0]
            content.title = "新资讯"
            content.body = notice.title
            content.userInfo = [
                "destination": AppRouter.destNewsDetail,
                "news_id": notice.id,
            ]
        } else {
            content.title = "有新资讯"
            content.body = "\(notices.count) 条新资讯：\(notices[0].title)"
            content.userInfo = ["destination": AppRouter.destNews]
        }
        // 前缀 + 时间戳：不覆盖未读历史（与 Android 固定 id 覆盖式的记录偏差）
        let identifier = "news-\(Int(Date().timeIntervalSince1970 * 1000))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await center.add(request)
    }
}
