import SwiftUI
import OpenJWCCore

/// 附件选择 sheet（对齐 Android NewsAttachmentSheet）：数据源 → 栏目 → 资讯三层选择。
struct AttachmentSheet: View {
    /// 选中回调（单选即回）。
    let onSelect: (ChatAttachment) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(ReactiveStore.self) private var reactive
    @Environment(\.dismiss) private var dismiss

    @State private var sourceId: String?
    @State private var labels: [String] = []
    @State private var notices: [NoticeRecord] = []
    @State private var selectedLabel: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                Section("数据源") {
                    Picker("数据源", selection: $sourceId) {
                        Text("全部").tag(String?.none)
                        ForEach(reactive.sources, id: \.id) { source in
                            Text(source.name).tag(String?.some(source.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: sourceId) { _, _ in
                        Task { await loadLabels() }
                    }
                }

                Section("栏目") {
                    if labels.isEmpty && loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else {
                        Picker("栏目", selection: $selectedLabel) {
                            ForEach(labels, id: \.self) { label in
                                Text(label).tag(String?.some(label))
                            }
                        }
                        .pickerStyle(.inline)
                        .onChange(of: selectedLabel) { _, _ in
                            Task { await loadNotices() }
                        }
                    }
                }

                if !notices.isEmpty {
                    Section("资讯（选前 60 条）") {
                        ForEach(notices, id: \.id) { notice in
                            Button {
                                onSelect(ChatAttachment(id: notice.id, title: notice.title))
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(notice.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text("\(notice.label) · \(notice.publishedDay)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else if selectedLabel != nil && !loading {
                    Text("该栏目暂无资讯")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("引用资讯")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await loadLabels() }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadLabels() async {
        loading = true
        defer { loading = false }
        let subscribed = (try? await environment.sourceDao.getSubscribed()) ?? []
        let picked = sourceId.map { id in subscribed.filter { $0.id == id } } ?? subscribed
        var seen = Set<String>()
        let declared = picked.flatMap(\.labels.value).filter { seen.insert($0).inserted }
        let extra = ((try? await environment.noticeDao.distinctLabelsBySource(sourceId: sourceId)) ?? [])
            .filter { !declared.contains($0) }
        labels = declared + extra
        if selectedLabel == nil || !labels.contains(selectedLabel ?? "") {
            selectedLabel = labels.first
        }
        await loadNotices()
    }

    private func loadNotices() async {
        guard let label = selectedLabel else {
            notices = []
            return
        }
        loading = true
        defer { loading = false }
        // 对齐 Android attachmentNotices：limit 60
        notices = (try? await environment.noticeDao.listByLabel(
            label: label, sourceId: sourceId, limit: 60, offset: 0
        )) ?? []
    }
}
