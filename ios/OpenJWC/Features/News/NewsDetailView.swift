import SwiftUI
import MarkdownUI
import OpenJWCCore

/// 详情页（对齐 Android NewsDetailScreen）：Markdown 正文、按 id 恢复滚动位置、
/// 图片进全屏查看器、附件与「在浏览器打开」交系统浏览器、收藏入口。
struct NewsDetailView: View {
    let noticeId: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @Environment(ReactiveStore.self) private var reactive
    @Environment(NewsStore.self) private var news

    @State private var notice: NoticeRecord?
    @State private var scrollPosition = ScrollPosition()
    @State private var appearedOnce = false

    /// 详情页滚动位置表（对齐 Android detailScrollOffsets：按资讯 id）。
    nonisolated(unsafe) private static var scrollOffsets: [String: CGFloat] = [:]

    var body: some View {
        Group {
            if let notice {
                content(notice)
            } else {
                ContentUnavailableView("资讯不存在", systemImage: "newspaper",
                                       description: Text("该资讯可能已被清理"))
            }
        }
        .navigationTitle(notice?.title ?? "详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let notice {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await news.setFavorite(id: notice.id, !notice.favorite) }
                    } label: {
                        Image(systemName: notice.favorite ? "bookmark.fill" : "bookmark")
                    }
                }
            }
        }
        .task {
            if notice == nil {
                notice = try? await environment.noticeDao.findById(id: noticeId)
            }
        }
    }

    @ViewBuilder
    private func content(_ notice: NoticeRecord) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    header(notice)
                        .id(notice.id)

                    if notice.contentVersion < 1,
                       notice.content?.isEmpty != false, notice.isPage {
                        Label("正文暂缺：可能是附件型通知或校内限制，下次抓取会自动重试", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Markdown(notice.content ?? "_该资讯暂无正文_")
                        .markdownTheme(theme)
                        .markdownImageProvider(
                            ViewerImageProvider { urlString in
                                router.viewerImageURL = urlString
                            }
                        )

                    attachments(notice)
                }
                .padding(16)
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newValue in
                Self.scrollOffsets[notice.id] = max(0, newValue)
            }
            .task {
                // 恢复滚动位置：等正文布局长起来再滚（对齐 Android 等 maxValue >= saved 的思路）
                let saved = Self.scrollOffsets[notice.id] ?? 0
                guard saved > 4, !appearedOnce else { return }
                try? await Task.sleep(for: .milliseconds(120))
                scrollPosition.scrollTo(y: saved)
                appearedOnce = true
            }
        }
    }

    private func header(_ notice: NoticeRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(notice.title)
                .font(.title3.bold())
            HStack(spacing: 10) {
                Text(notice.label)
                Text(notice.publishedDay)
                Button("在浏览器打开") {
                    if let url = URL(string: notice.detailUrl) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.caption)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func attachments(_ notice: NoticeRecord) -> some View {
        let urls = (notice.attachments?.value ?? []).compactMap(URL.init(string:))
        if !urls.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("附件")
                    .font(.subheadline.bold())
                ForEach(urls, id: \.absoluteString) { url in
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label(url.lastPathComponent, systemImage: "paperclip")
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// 场景「查看图片」：正文图片点击 → 全屏查看器（AppRouter.viewerImageURL）。
    private struct ViewerImageProvider: ImageProvider {
        let onOpen: (String) -> Void

        func makeImage(url: URL?) -> some View {
            Group {
                if let url {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFit()
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                                if phase.error != nil {
                                    Image(systemName: "photo.badge.exclamationmark")
                                } else {
                                    ProgressView()
                                }
                            }
                            .aspectRatio(16 / 9, contentMode: .fit)
                        }
                    }
                    .onTapGesture { onOpen(url.absoluteString) }
                }
            }
        }
    }

    /// D-3：MarkdownUI 主题（基础主题 + 代码块样式，随系统配色）。
    private var theme: Theme {
        Theme.basic
            .text {
                FontSize(15)
            }
            .codeBlock { configuration in
                configuration.label
                    .font(.callout.monospaced())
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
    }
}
