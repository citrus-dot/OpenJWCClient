import SwiftUI
import OpenJWCCore

/// 资讯 tab 根视图：详情栈 + 收藏页压栈 + 深链消费 + 响应式计数桥接。
struct NewsRootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @Environment(ReactiveStore.self) private var reactive
    @Environment(NewsStore.self) private var news

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.newsPath) {
            NewsListView()
                .navigationDestination(for: String.self) { noticeId in
                    NewsDetailView(noticeId: noticeId)
                }
                .navigationDestination(isPresented: $router.favoritesPresented) {
                    FavoriteListView()
                }
        }
        .fullScreenCover(item: Binding(
            get: {
                router.viewerImageURL.flatMap(URL.init(string:)).map(ImagePayload.init)
            },
            set: { router.viewerImageURL = $0?.url.absoluteString }
        )) { payload in
            ImageViewer(url: payload.url) {
                router.viewerImageURL = nil
            }
        }
        // 场景「抓取后计数自动更新」：总数变化 → 重读已载栏目
        .onChange(of: reactive.noticeCount) { _, _ in
            Task { await news.refreshLoadedLabels() }
        }
        // 场景「点单条资讯通知」：消费深链待开的详情
        .onChange(of: router.pendingDetailId) { _, newId in
            guard let id = newId else { return }
            Task { await consumePendingDetail(id) }
        }
        .task { await loadLabelsIfNeeded() }
    }

    private func loadLabelsIfNeeded() async {
        guard news.labels.isEmpty else { return }
        await news.loadLabels()
    }

    /// 场景「无效 id 降级」：id 在库中不存在时仅切 tab，不开空白详情。
    private func consumePendingDetail(_ id: String) async {
        router.pendingDetailId = nil
        guard (try? await environment.noticeDao.findById(id: id)) != nil else { return }
        if !router.newsPath.contains(id) {
            router.newsPath.append(id)
        }
    }
}

/// fullScreenCover(item:) 的载荷（避免 String 追加 retroactive conformance）。
private struct ImagePayload: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
