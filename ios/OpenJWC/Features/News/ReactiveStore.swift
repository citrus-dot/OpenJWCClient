import Foundation
import GRDB
import OpenJWCCore

/// 三条 ValueObservation → @Observable 桥（D-2）：
/// 订阅源列表、收藏列表、资讯总数。分页列表查询保持命令式（NewsStore）。
/// 单例生命周期挂载（AppEnvironment 持有），观察值随数据变化自动推送。
@MainActor
@Observable
final class ReactiveStore {
    /// 订阅源（排序对齐 Android observeSubscribed：subscribed DESC、seu-jwc 置顶）。
    private(set) var sources: [NoticeSourceRecord] = []
    /// 收藏列表（对齐 observeFavorites）。
    private(set) var favorites: [NoticeRecord] = []
    /// 资讯总数（抓取落库后驱动已载栏目重读）。
    private(set) var noticeCount: Int = 0

    private var cancellables: [any DatabaseCancellable] = []

    init(db: any DatabaseWriter) {
        // 链式模式 + removeDuplicates，不标注返回类型（D-2：避免 Reducer 约束编译错）
        let sourcesObs = ValueObservation.tracking { db in
            try SourceDao.subscribedSync(db)
        }
        .removeDuplicates()

        let favoritesObs = ValueObservation.tracking { db in
            try NoticeDao.favoritesSync(db)
        }
        .removeDuplicates()

        let countObs = ValueObservation.tracking { db in
            try NoticeDao.totalCountSync(db)
        }
        .removeDuplicates()

        cancellables.append(sourcesObs.start(in: db, onError: Self.logError) { [weak self] value in
            Task { @MainActor in self?.sources = value }
        })
        cancellables.append(favoritesObs.start(in: db, onError: Self.logError) { [weak self] value in
            Task { @MainActor in self?.favorites = value }
        })
        cancellables.append(countObs.start(in: db, onError: Self.logError) { [weak self] value in
            Task { @MainActor in self?.noticeCount = value }
        })
    }

    private static func logError(_ error: Error) {
        NSLog("ReactiveStore 观察错误: \(error)")
    }
}
