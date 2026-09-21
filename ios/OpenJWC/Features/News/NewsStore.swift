import Foundation
import GRDB
import OpenJWCCore

/// 资讯流状态机（对齐 Android NewsViewModel）：栏目 tab + 每栏目独立分页 + 源筛选。
/// 分页查询为命令式一次性查询；响应式部分（sources/favorites/noticeCount）在 ReactiveStore。
@MainActor
@Observable
final class NewsStore {
    struct PagingState: Equatable {
        var items: [NoticeRecord] = []
        var currentPage = 1
        var isEnd = false
        var error: String?
    }

    static let pageSize = 20

    /// 栏目顺序：订阅源声明 @labels 在前，语料额外栏目补后（对齐 getLocalLabels）。
    private(set) var labels: [String] = []
    private(set) var paging: [String: PagingState] = [:]
    private(set) var labelError: String?
    private(set) var isLoadingPage = false
    /// 当前源筛选：nil = 全部数据源。
    var sourceFilter: String?
    /// fresh 高亮窗口快照（设置改动入口在阶段 8，快照足够）。
    let freshDays: Int

    private let noticeDao: NoticeDao
    private let sourceDao: SourceDao

    init(db: any DatabaseWriter, settings: SettingsStore) {
        self.noticeDao = NoticeDao(db: db)
        self.sourceDao = SourceDao(db: db)
        self.freshDays = settings.loadUserSettings().freshDays
    }

    // MARK: - 栏目

    func loadLabels() async {
        do {
            let subscribed = try await sourceDao.getSubscribed()
            let picked = sourceFilter.map { id in subscribed.filter { $0.id == id } } ?? subscribed
            let declared = picked.flatMap(\.labels.value).removingDuplicates
            let extra = try await noticeDao.distinctLabelsBySource(sourceId: sourceFilter)
                .filter { !declared.contains($0) }
            labels = declared + extra
            labelError = nil
        } catch {
            labelError = error.localizedDescription
        }
    }

    // MARK: - 分页（LIMIT/OFFSET=20，场景「首次进入栏目加载」「栏目状态互不干扰」）

    func loadCategoryIfNeeded(_ label: String) async {
        guard paging[label] == nil else { return }
        await loadPage(label, page: 1)
    }

    /// 倒数第 2 项预载调用；到底（返回 < 20）不再追加。
    func loadNextPage(_ label: String) async {
        guard !isLoadingPage, let state = paging[label], !state.isEnd else { return }
        await loadPage(label, page: state.currentPage + 1)
    }

    /// 下拉刷新后的当前栏目重读（第一页）。
    func reloadFirstPage(_ label: String) async {
        await loadPage(label, page: 1)
    }

    private func loadPage(_ label: String, page: Int) async {
        isLoadingPage = true
        paging[label, default: PagingState()].error = nil
        defer { isLoadingPage = false }
        do {
            let offset = (page - 1) * Self.pageSize
            let fresh = try await noticeDao.listByLabel(
                label: label, sourceId: sourceFilter,
                limit: Self.pageSize, offset: offset
            )
            let isEnd = fresh.count < Self.pageSize
            if page == 1 {
                paging[label] = PagingState(items: fresh, currentPage: 1, isEnd: isEnd)
            } else {
                var current = paging[label] ?? PagingState()
                var merged = current.items
                for item in fresh where !merged.contains(where: { $0.id == item.id }) {
                    merged.append(item)
                }
                current.items = merged
                current.currentPage = page
                current.isEnd = isEnd
                paging[label] = current
            }
        } catch {
            paging[label, default: PagingState()].error = error.localizedDescription
        }
    }

    /// 抓取落库后：重读已加载栏目（保持已翻页数），不改动刷新指示器。
    /// 由视图层监听 ReactiveStore.noticeCount 变化调用（场景「抓取后计数自动更新」）。
    func refreshLoadedLabels() async {
        for label in paging.keys {
            guard let state = paging[label] else { continue }
            let limit = state.currentPage * Self.pageSize
            guard let items = try? await noticeDao.listByLabel(
                label: label, sourceId: sourceFilter, limit: limit, offset: 0
            ) else { continue }
            paging[label]?.items = items
        }
    }

    // MARK: - 源筛选（场景「切换重置栏目与分页状态并重载」）

    func setSourceFilter(_ sourceId: String?) async {
        guard sourceFilter != sourceId else { return }
        sourceFilter = sourceId
        labels = []
        paging = [:]
        await loadLabels()
    }

    // MARK: - 收藏操作

    func setFavorite(id: String, _ favorite: Bool) async {
        try? await noticeDao.setFavorite(id: id, favorite: favorite)
    }

    func removeFavorite(id: String) async {
        await setFavorite(id: id, false)
    }

    func clearFavorites() async {
        try? await noticeDao.clearFavorites()
    }
}

private extension Array where Element == String {
    var removingDuplicates: [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
