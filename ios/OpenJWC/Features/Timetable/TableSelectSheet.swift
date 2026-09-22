import SwiftUI
import OpenJWCCore
import UniformTypeIdentifiers

/// 表选择 sheet（对齐 Android TableSelectSheet；型同 SourceFilterSheet）：
/// 列表 + 当前高亮 + 新建 + 导入入口（fileImporter 挂在本 sheet 内，避免与上层 sheet 呈现冲突）。
struct TableSelectSheet: View {
    let tables: [TableMetadataRecord]
    let currentId: Int64?
    let onSelect: (TableMetadataRecord) -> Void
    let onCreate: () -> Void
    /// 解析成功 → 根视图切换到导入预览。
    let onParsed: (TimetableJson.ParseResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tables, id: \.id) { table in
                        Button {
                            onSelect(table)
                            dismiss()
                        } label: {
                            row(table: table)
                        }
                    }
                }
                Section {
                    Button {
                        onCreate()
                        dismiss()
                    } label: {
                        Label("新建空白课表", systemImage: "plus")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入 JSON 文件", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .navigationTitle("切换课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .failure(let error):
                    errorText = "读取文件失败：\(error.localizedDescription)"
                case .success(let url):
                    do {
                        onParsed(try TimetableImport.parseFile(at: url))
                    } catch let error as TimetableJson.ParseError {
                        errorText = error.errorDescription
                    } catch {
                        errorText = "读取文件失败：\(error.localizedDescription)"
                    }
                }
            }
            .alert(
                "提示",
                isPresented: Binding(
                    get: { errorText != nil },
                    set: { if !$0 { errorText = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(table: TableMetadataRecord) -> some View {
        let selected = table.id == currentId
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(table.tableName)
                    .font(.body.weight(selected ? .bold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(table.semesterConfig.weeks) 周 · \(table.semesterConfig.periods.count) 节")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
    }
}
