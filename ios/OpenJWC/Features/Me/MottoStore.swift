import Foundation
import OpenJWCCore

/// 格言状态（对齐 Android MeViewModel motto 部分）：取值优先级 + 懒刷新。
/// mottoOnline=true → 缓存一言（按天，不新鲜才拉）；false → 本地格言。
@MainActor
@Observable
final class MottoStore {
    private(set) var motto = Motto.defaultOnline
    private(set) var refreshing = false
    /// 最近一次刷新失败提示（自动消失由视图层控制）。
    private(set) var lastError: String?

    private let settings: SettingsStore
    private let cache: MottoCache
    private let client = HitokotoClient()
    /// 已在本进程拉取成功过（避免同日多次进入重复拉——缓存已覆盖，防御时钟回拨）。
    private var fetchedToday = false

    init(settings: SettingsStore, cache: MottoCache = MottoCache()) {
        self.settings = settings
        self.cache = cache
        motto = resolve()
    }

    /// 取值优先级（对齐 Android MeViewModel.motto）。
    private func resolve() -> Motto {
        let user = settings.loadUserSettings()
        if user.mottoOnline {
            return cache.loadOrDefault()
        }
        return Motto.local(text: user.mottoText, author: user.mottoAuthor)
    }

    /// 设置变更后重解析（MottoSettings 保存后调用）。
    func reload() {
        fetchedToday = false
        motto = resolve()
    }

    /// 懒刷新（对齐 Android refreshMottoLazily）：本地模式跳过；当日新鲜跳过。
    func refreshLazily() async {
        let user = settings.loadUserSettings()
        guard user.mottoOnline, !fetchedToday else { return }
        if let cached = cache.load(), MottoCache.isFresh(cached) {
            motto = cached
            return
        }
        await refresh()
    }

    /// 手动刷新（仅在线模式；本地模式为 no-op——修复：关在线开关后「换一句」仍可拉取）。
    func refresh() async {
        guard settings.loadUserSettings().mottoOnline, !refreshing else { return }
        refreshing = true
        lastError = nil
        defer { refreshing = false }
        let user = settings.loadUserSettings()
        do {
            let fetched = try await client.fetch(
                category: user.hitokotoCategory,
                minLength: 0,
                maxLength: user.hitokotoMaxLength
            )
            cache.save(fetched)
            motto = fetched
            fetchedToday = true
        } catch {
            lastError = error.localizedDescription
        }
    }
}
