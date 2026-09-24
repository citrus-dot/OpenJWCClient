import SwiftUI
import UserNotifications
import OpenJWCCore

/// 通知设置页（design D-3/D-8，spec「通知设置页/通知权限申请」Requirement）：
/// 新闻通知分组（开关 + 间隔 Picker，关时间隔置灰）+ 课程提醒开关 + 权限状态行。
/// 裁剪记录：Android「电池优化豁免」「自启动」两开关在 iOS 无对应概念（后台调度系统托管）。
/// 开关即时生效：写入 SettingsStore → BackgroundTaskCoordinator.syncAll（对齐课表四开关 reloadPrefs 模式）。
struct NotificationSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    /// 本页快照（onAppear 加载；保存后回写）。
    @State private var settings = UserSettings()
    /// 拒绝权限后的确认弹窗状态。
    @State private var deniedOnce = false

    private var authorizer: NotificationAuthorizer { environment.notificationAuthorizer }

    private static let intervalOptions: [(minutes: Int, label: String)] = [
        (15, "15 分钟"), (30, "30 分钟"), (60, "1 小时"),
        (180, "3 小时"), (360, "6 小时"),
    ]

    var body: some View {
        List {
            newsSection
            courseSection
            permissionSection
        }
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            settings = environment.settings.loadUserSettings()
            await authorizer.refreshStatus()
        }
        // 从系统设置返回时刷新权限状态（对齐 Android ON_RESUME）
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await authorizer.refreshStatus() }
        }
    }

    // MARK: - 新闻通知

    private var newsSection: some View {
        Section {
            Toggle("新闻通知", isOn: Binding(
                get: { settings.newsNotificationEnabled },
                set: { on in Task { await toggleNews(on) } }
            ))
            Picker("检查间隔", selection: Binding(
                get: { settings.newsCheckIntervalMinutes },
                set: { minutes in save { $0.newsCheckIntervalMinutes = minutes } }
            )) {
                ForEach(Self.intervalOptions, id: \.minutes) { option in
                    Text(option.label).tag(option.minutes)
                }
            }
            .disabled(!settings.newsNotificationEnabled)
        } header: {
            Text("新闻通知")
        } footer: {
            Text("后台任务由 iOS 系统统一调度，实际执行时间可能晚于设定值。")
        }
    }

    // MARK: - 课程提醒

    private var courseSection: some View {
        Section {
            Toggle("课程提醒", isOn: Binding(
                get: { settings.courseReminderEnabled },
                set: { on in Task { await toggleCourseReminder(on) } }
            ))
        } header: {
            Text("课程提醒")
        } footer: {
            Text("上课前 10 分钟提醒，提前注册未来 14 天内的课程。")
        }
    }

    // MARK: - 权限状态

    @ViewBuilder
    private var permissionSection: some View {
        Section {
            switch authorizer.authorizationStatus {
            case .denied:
                Button {
                    authorizer.openSystemSettings()
                } label: {
                    Label("通知权限已关闭，去系统设置开启", systemImage: "gear")
                }
            case .notDetermined:
                Label("尚未请求通知权限", systemImage: "bell.badge")
                    .foregroundStyle(.secondary)
            default:
                Label("通知权限已开启", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("系统权限")
        }
    }

    // MARK: - 操作

    /// 统一保存 + 即时生效（对齐课表四开关 reloadPrefs 模式：写设置 → 全量同步）。
    private func save(_ mutate: (inout UserSettings) -> Void) {
        var updated = environment.settings.loadUserSettings()
        mutate(&updated)
        environment.settings.saveUserSettings(updated)
        settings = updated
        Task { await environment.backgroundTasks.syncAll() }
    }

    /// 开新闻通知：权限未决 → 弹窗；授予 → 生效 + 立即抓取一次（runOnce 等价）；拒绝 → 回弹 + 引导。
    private func toggleNews(_ on: Bool) async {
        if on {
            let granted = await authorizer.requestIfNeeded()
            guard granted else { return } // 开关回弹（get 不变），拒绝引导行自动出现
            save { $0.newsNotificationEnabled = true }
            await environment.backgroundTasks.crawlOnce()
        } else {
            save { $0.newsNotificationEnabled = false } // syncAll 内取消后台任务
        }
    }

    /// 开课程提醒：同样先确保权限（拒绝则回弹）；syncAll → reschedule（关 → 清空待发）。
    private func toggleCourseReminder(_ on: Bool) async {
        if on {
            let granted = await authorizer.requestIfNeeded()
            guard granted else { return }
        }
        save { $0.courseReminderEnabled = on }
    }
}
