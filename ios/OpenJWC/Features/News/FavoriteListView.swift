import SwiftUI
import OpenJWCCore

/// 收藏页（场景「收藏并查看」「清空收藏」）：响应式列表、单项删除、清空确认。
struct FavoriteListView: View {
    @Environment(ReactiveStore.self) private var reactive
    @Environment(NewsStore.self) private var news
    @Environment(AppRouter.self) private var router

    @State private var confirmClear = false

    var body: some View {
        Group {
            if reactive.favorites.isEmpty {
                ContentUnavailableView("暂无收藏", systemImage: "bookmark",
                                       description: Text("在资讯卡片或详情页点亮星标即可收藏"))
            } else {
                list
            }
        }
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空") { confirmClear = true }
                    .disabled(reactive.favorites.isEmpty)
            }
        }
        .confirmationDialog("清空全部收藏？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空收藏", role: .destructive) {
                Task { await news.clearFavorites() }
            }
        } message: {
            Text("清空后不可恢复")
        }
    }

    private var list: some View {
        List {
            ForEach(reactive.favorites, id: \.id) { notice in
                Button {
                    router.newsPath.append(notice.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notice.title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(notice.label) · \(notice.publishedDay)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { indexes in
                let ids = indexes.map { reactive.favorites[$0].id }
                Task {
                    for id in ids { await news.removeFavorite(id: id) }
                }
            }
        }
    }
}
