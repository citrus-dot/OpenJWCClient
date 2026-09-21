import SwiftUI
import OpenJWCCore

/// 源筛选 sheet（对齐 Android SourceSelectSheet）：首项「全部数据源」+ 逐订阅源单选，选中即关。
struct SourceFilterSheet: View {
    let sources: [NoticeSourceRecord]
    let selectedSourceId: String?
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    row(title: "全部数据源", detail: "聚合所有已订阅数据源", selected: selectedSourceId == nil)
                }

                ForEach(sources, id: \.id) { source in
                    Button {
                        onSelect(source.id)
                        dismiss()
                    } label: {
                        row(
                            title: source.name,
                            detail: "\(source.id) · 已订阅",
                            selected: source.id == selectedSourceId
                        )
                    }
                }
            }
            .navigationTitle("切换数据源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(title: String, detail: String, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(selected ? .bold : .regular))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
    }
}
