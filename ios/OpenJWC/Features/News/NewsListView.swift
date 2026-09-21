import SwiftUI
import UserNotifications
import OpenJWCCore

/// 资讯流列表（场景：栏目 tab / 网格 / 分页预载 / 下拉刷新 / 源筛选）。
struct NewsListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @Environment(ReactiveStore.self) private var reactive
    @Environment(NewsStore.self) private var news
    @Environment(CrawlCoordinator.self) private var crawl

    @State private var showSourceSheet = false
    @State private var showProgress = false
    /// 选中栏目；各栏目独立分页状态存在 NewsStore.paging（场景「栏目状态互不干扰」）。
    @State private var selectedLabel: String?

    var body: some View {
        GeometryReader { proxy in
            content(columnCount: Self.columnCount(for: proxy.size.width))
        }
        .navigationTitle(currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // 标题 + 下拉箭头 = 源筛选入口（对齐 Android 顶栏）
                Button {
                    showSourceSheet = true
                } label: {
                    HStack(spacing: 3) {
                        Text(currentTitle)
                            .fontWeight(.semibold)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.favoritesPresented = true
                } label: {
                    Image(systemName: "bookmark")
                }
                .accessibilityLabel("收藏")
            }
            #if DEBUG
            // 深链手验（阶段 4 临时调试入口；阶段 8 随通知注册一并移除）
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("5s 后通知：打开单条详情") {
                        let id = displayItems.first?.id ?? "not-exist-id"
                        scheduleTestNotification(destination: AppRouter.destNewsDetail, newsId: id)
                    }
                    Button("5s 后通知：打开资讯 tab") {
                        scheduleTestNotification(destination: AppRouter.destNews, newsId: nil)
                    }
                    Button("5s 后通知：无效 id（降级）") {
                        scheduleTestNotification(destination: AppRouter.destNewsDetail, newsId: "definitely-not-exist")
                    }
                } label: {
                    Image(systemName: "bell.badge")
                }
            }
            #endif
        }
        .sheet(isPresented: $showSourceSheet) {
            SourceFilterSheet(
                sources: reactive.sources,
                selectedSourceId: news.sourceFilter
            ) { sourceId in
                Task { await news.setSourceFilter(sourceId) }
            }
        }
        .sheet(isPresented: $showProgress) {
            CrawlProgressPanel()
                .presentationDetents([.medium, .large])
        }
        .onChange(of: crawl.progress.running) { oldValue, newValue in
            // 场景「手动触发全量抓取」：抓取开始自动弹进度面板（对齐 Android 对话框）
            if newValue && !oldValue { showProgress = true }
        }
    }

    @ViewBuilder
    private func content(columnCount: Int) -> some View {
        VStack(spacing: 0) {
            labelTabs

            if let error = news.labelError, news.labels.isEmpty {
                ContentUnavailableView("加载失败", systemImage: "wifi.exclamationmark",
                                       description: Text(error))
                Spacer()
            } else if news.labels.isEmpty {
                ProgressView().padding(.top, 60)
                Spacer()
            } else {
                grid(columnCount: columnCount)
            }
        }
    }

    // MARK: - 栏目 tab（可滚动）

    private var labelTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(news.labels, id: \.self) { label in
                    LabelTab(
                        title: label,
                        selected: label == selectedLabel,
                        action: { selectedLabel = label }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onChange(of: news.labels) { _, labels in
            if selectedLabel == nil || !labels.contains(selectedLabel ?? "") {
                selectedLabel = labels.first
            }
        }
        .task(id: selectedLabel) {
            // 场景「首次进入栏目加载」：未加载过的栏目拉第一页
            guard let selectedLabel else { return }
            await news.loadCategoryIfNeeded(selectedLabel)
        }
    }

    // MARK: - 网格

    private func grid(columnCount: Int) -> some View {
        ScrollView {
            LazyVGrid(columns: gridItems(columnCount), spacing: 12) {
                ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, notice in
                    NewsCardView(
                        notice: notice,
                        isFavorited: reactive.favorites.contains { $0.id == notice.id },
                        freshDays: news.freshDays,
                        onToggleFavorite: {
                            Task { await news.setFavorite(id: notice.id, !notice.favorite) }
                        },
                        onOpen: { router.newsPath.append(notice.id) }
                    )
                    .onAppear {
                        // 场景「滑动到底自动追加下一页」：倒数第 2 项触发预载
                        if index >= displayItems.count - 2, let label = currentLabel {
                            Task { await news.loadNextPage(label) }
                        }
                    }
                }

                if displayItems.isEmpty && !news.isLoadingPage {
                    emptyPlaceholder
                }

                if news.isLoadingPage && !displayItems.isEmpty {
                    HStack { ProgressView().padding(.vertical, 16) }
                }

                if let label = currentLabel, let state = news.paging[label], state.isEnd,
                   !state.items.isEmpty {
                    Text("已加载全部内容")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(16)
                }
            }
            .padding(.horizontal, 16)
        }
        .refreshable { await pullToRefresh() }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "newspaper")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("该栏目暂无资讯")
                .font(.headline)
            Text("下拉抓取已订阅数据源，新资讯会自动出现")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 64)
    }

    // MARK: - 深链手验（阶段 4 临时调试入口；阶段 8 随通知注册一并移除）

    #if DEBUG
    private func scheduleTestNotification(destination: String, newsId: String?) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            var userInfo: [String: Any] = ["destination": destination]
            if let newsId { userInfo["news_id"] = newsId }
            let content = UNMutableNotificationContent()
            content.title = "深链测试"
            content.body = destination == AppRouter.destNewsDetail
                ? "打开详情：\(newsId ?? "-")" : "打开资讯 tab"
            content.userInfo = userInfo
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            let request = UNNotificationRequest(
                identifier: "debug-deeplink-\(UUID().uuidString)",
                content: content, trigger: trigger
            )
            center.add(request)
        }
    }
    #endif

    // MARK: - 数据整形

    /// 当前展示的栏目。
    private var currentLabel: String? {
        selectedLabel ?? news.labels.first
    }

    private var displayItems: [NoticeRecord] {
        guard let label = currentLabel else { return [] }
        return news.paging[label]?.items ?? []
    }

    private var currentTitle: String {
        guard let id = news.sourceFilter else { return "资讯" }
        return reactive.sources.first { $0.id == id }?.name ?? "资讯"
    }

    /// 场景「手动触发全量抓取」：抓当前筛选范围内的订阅源，完成后重读当前栏目第一页；
    /// 其余已载栏目由 noticeCount 观察触发重读。
    private func pullToRefresh() async {
        var sources = reactive.sources
        if let filter = news.sourceFilter {
            sources = sources.filter { $0.id == filter }
        }
        guard !sources.isEmpty else { return }

        crawl.startCrawl(sources: sources, crawlDaysGap: environment.settings.loadUserSettings().crawlDaysGap)
        await crawl.awaitCompletion()

        if let label = currentLabel {
            await news.reloadFirstPage(label)
        }
        await news.refreshLoadedLabels()
    }

    // MARK: - 列数（D-7 对齐 Android 窗口宽度断点 1/2/3）

    static func columnCount(for width: CGFloat) -> Int {
        if width < 600 { return 1 }
        if width < 900 { return 2 }
        return 3
    }

    private func gridItems(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }
}

private struct LabelTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}
