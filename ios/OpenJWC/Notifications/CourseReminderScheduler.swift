import Foundation
import UserNotifications
import OpenJWCCore

/// 课程提醒调度器（design D-4，spec「课程提醒通知」Requirement）：
/// CourseReminderPlan 纯函数 → UNTimeIntervalNotificationTrigger 注册；
/// 全量取消本类（前缀过滤）后重新注册，触发时机对齐 Android：
/// App 启动 / courseReminderEnabled 变化 / 当前表或课程变化。
/// 裁剪记录：BOOT/时间变更广播恢复在 iOS 无对应概念（系统持久存储 + 每次启动全量重排覆盖）。
@MainActor
final class CourseReminderScheduler {
    /// 稳定 id 前缀（D-4：确定性派生使全量取消可按前缀过滤，无需记账）。
    static let idPrefix = "course-"
    static let threadIdentifier = "courseReminder"

    private let settings: SettingsStore
    private let timetable: TimetableStore
    private let center = UNUserNotificationCenter.current()

    init(settings: SettingsStore, timetable: TimetableStore) {
        self.settings = settings
        self.timetable = timetable
    }

    /// 全量重排：清空本类待发 → 依据开关/权限/课表重注册（幂等，可任意时机调用）。
    func reschedule() async {
        // 1. 前缀过滤全量取消本类
        let pending = await center.pendingNotificationRequests()
        let ownIds = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        if !ownIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ownIds)
        }

        // 2. 关闭开关 / 无当前表 → 清空即完成
        let userSettings = settings.loadUserSettings()
        guard userSettings.courseReminderEnabled, let table = timetable.currentTable else { return }

        // 3. 权限被拒/未决 → 不注册（保持清空；权限引导由设置页负责）
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        // 4. 注册计划（core 纯函数已含 14 天窗口 + 64 条截断保近端）
        let snapshot = WidgetSnapshot(table: table, courses: timetable.courses)
        let plan = CourseReminderPlan.build(snapshot: snapshot, now: Date())
        guard !plan.isEmpty else { return }

        let now = Date()
        for item in plan {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.threadIdentifier = Self.threadIdentifier
            content.userInfo = ["destination": AppRouter.destTimetable]
            let interval = max(item.fireDate.timeIntervalSince(now), 0.1)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(
                identifier: item.identifier, content: content, trigger: trigger
            )
            try? await center.add(request)
        }
    }
}
