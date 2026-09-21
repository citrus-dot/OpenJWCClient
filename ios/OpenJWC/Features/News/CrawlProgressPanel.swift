import SwiftUI
import OpenJWCCore

/// 抓取进度面板（对齐 Android CrawlProgressDialog）：进度 / 当前源 / 结果 / 日志 / 取消。
struct CrawlProgressPanel: View {
    @Environment(CrawlCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        ProgressView(value: overallFraction) {
                            Text(header)
                                .font(.subheadline)
                        }
                        if let current = coordinator.progress.currentSourceName {
                            Text("正在抓取：\(current)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !coordinator.progress.results.isEmpty {
                    Section("结果") {
                        ForEach(Array(coordinator.progress.results.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption)
                        }
                    }
                }

                Section("日志") {
                    ForEach(Array(coordinator.progress.logs.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("抓取进度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(coordinator.progress.running ? "取消" : "关闭") {
                        if coordinator.progress.running {
                            coordinator.cancelCrawl()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    private var overallFraction: Double {
        guard coordinator.progress.total > 0 else { return 0 }
        let base = Double(coordinator.progress.finished) / Double(coordinator.progress.total)
        let inSource = (coordinator.progress.currentSourceName != nil)
            ? coordinator.progress.currentFraction / Double(coordinator.progress.total)
            : 0
        return min(base + inSource, 1)
    }

    private var header: String {
        let p = coordinator.progress
        return p.running ? "已完成 \(p.finished)/\(p.total) 个数据源" : "抓取结束（\(p.finished)/\(p.total)）"
    }
}
