import Foundation
import UIKit
import UserNotifications

/// 通知权限（design D-3）：仅在设置页开关操作时申请（不启动即弹），
/// 状态查询 + 系统设置跳转 + 回前台刷新（Android ON_RESUME 等价）。
@MainActor
@Observable
final class NotificationAuthorizer {
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()

    /// 从系统回读权限状态（onAppear / scenePhase 回前台时调用）。
    func refreshStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// 未决（首次操作）时弹系统申请；已授予返回 true，被拒/未决未申请返回 false。
    @discardableResult
    func requestIfNeeded() async -> Bool {
        if authorizationStatus == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            await refreshStatus()
            return granted
        }
        return authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    /// 是否已授权（发送前判定）。
    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    /// 被拒后的「去系统设置」引导（对齐 Android openNotificationSettings）。
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
