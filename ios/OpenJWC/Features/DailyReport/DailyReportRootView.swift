import SwiftUI
import MarkdownUI
import OpenJWCCore

/// 日报 tab（对齐 Android DailyReportScreen 四态）：日期 chips + Markdown 正文 + 下拉刷新。
struct DailyReportRootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(DailyReportStore.self) private var store

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("日报")
                .navigationBarTitleDisplayMode(.inline)
        }
        .task { await store.reload() }
    }

    @ViewBuilder
    private var content: some View {
        if store.generating || store.loading && store.content == nil {
            stateView(title: "生成中…", systemImage: "doc.text.magnifyingglass") {
                ProgressView()
            }
        } else if let failedDay = store.failedDay {
            stateView(title: "生成失败", systemImage: "exclamationmark.triangle") {
                VStack(spacing: 8) {
                    Text("\(failedDay)：\(store.failureMessage ?? "未知错误")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") { Task { await store.generate() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if let content = store.content {
            dayChips
            reportBody(content)
        } else {
            stateView(title: "暂无日报", systemImage: "doc.text") {
                VStack(spacing: 8) {
                    Text("为最近一天已收录的资讯生成本地日报")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("生成日报") { Task { await store.generate() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var dayChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(store.completedDays.enumerated()), id: \.element.day) { index, record in
                    Button {
                        Task { await store.select(day: record.day) }
                    } label: {
                        Text(index == 0 ? "最新 · \(record.day)" : record.day)
                            .font(.caption.weight(store.selectedDay == record.day || (store.selectedDay == nil && index == 0) ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                (store.selectedDay == record.day || (store.selectedDay == nil && index == 0))
                                    ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func reportBody(_ content: String) -> some View {
        ScrollView {
            Markdown(content)
                .markdownTheme(.report)
                .padding(16)
        }
        .refreshable { await store.reload() }
    }

    private func stateView(title: String, systemImage: String, @ViewBuilder detail: () -> some View) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            detail()
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await store.reload() }
    }
}

/// 日报 Markdown 主题。
private extension Theme {
    static var report: Theme {
        Theme.basic.text { FontSize(15) }
    }
}
