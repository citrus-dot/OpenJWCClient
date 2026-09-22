import SwiftUI
import OpenJWCCore

/// Me tab 完整版：Hitokoto 头部 + 设置中心入口（对齐 Android MeScreen 三入口）。
struct MeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(MottoStore.self) private var mottoStore
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack {
            List {
                Section {
                    HitokotoHeaderView()
                        .listRowBackground(Color.clear)
                }

                Section {
                    NavigationLink {
                        SettingsHomeView()
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    NavigationLink {
                        FavoriteListView()
                    } label: {
                        Label("收藏资讯", systemImage: "bookmark")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("我的")
            .task { await mottoStore.refreshLazily() }
        }
    }
}

/// 格言头部（对齐 Android HitokotoView）：大字正文 + 署名 + permalink + 点击展开刷新（仅在线）。
struct HitokotoHeaderView: View {
    @Environment(MottoStore.self) private var mottoStore
    @Environment(\.openURL) private var openURL
    @State private var showRefresh = false

    var body: some View {
        @Bindable var mottoStore = mottoStore
        VStack(spacing: 8) {
            Text(mottoStore.motto.text)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            if let attribution = mottoStore.motto.attribution {
                Text(attribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let permalink = mottoStore.motto.permalink,
               let url = URL(string: permalink) {
                Button("hitokoto.cn") { openURL(url) }
                    .font(.caption2)
                    .buttonStyle(.borderless)
            }

            if showRefresh {
                Button {
                    Task { await mottoStore.refresh() }
                } label: {
                    if mottoStore.refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("换一句", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(mottoStore.refreshing)
            }

            if let error = mottoStore.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .contentShape(Rectangle())
        .onTapGesture {
            // 仅在线模式点击正文展开刷新（对齐 Android）
            if mottoStore.motto.permalink != nil {
                withAnimation(.easeInOut(duration: 0.2)) { showRefresh.toggle() }
            }
        }
    }
}
