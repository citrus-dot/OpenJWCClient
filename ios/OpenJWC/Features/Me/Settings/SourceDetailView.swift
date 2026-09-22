import SwiftUI
import OpenJWCCore

/// 来源详情页（对齐 Android SourceDetailScreen）：属性 / 订阅开关 / 立即抓取 /
/// 上次运行（lastError 全文）/ 脚本查看（内置只读）或编辑（侧载）/ 删除（仅侧载）。
struct SourceDetailView: View {
    let sourceId: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(CrawlCoordinator.self) private var crawl
    @Environment(\.dismiss) private var dismiss

    @State private var source: NoticeSourceRecord?
    @State private var scriptText = ""
    @State private var dirty = false
    @State private var saveMessage: String?
    @State private var confirmDelete = false
    @State private var showErrorFull = false

    private var isBuiltIn: Bool { source?.origin == "builtin" }

    var body: some View {
        Group {
            if let source {
                list(source)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(source?.name ?? "数据源")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog("删除该数据源？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { delete() }
        } message: {
            Text("脚本与订阅将被移除")
        }
        .alert("保存结果", isPresented: Binding(
            get: { saveMessage != nil },
            set: { if !$0 { saveMessage = nil } }
        )) {
            Button("好") { saveMessage = nil }
        } message: {
            Text(saveMessage ?? "")
        }
    }

    @ViewBuilder
    private func list(_ source: NoticeSourceRecord) -> some View {
        List {
            Section("属性") {
                LabeledContent("id", value: source.id)
                LabeledContent("版本", value: source.version)
                LabeledContent("类型", value: isBuiltIn ? "内置" : "侧载")
                LabeledContent("栏目", value: source.labels.value.joined(separator: "、"))
            }

            Section {
                Toggle("订阅", isOn: Binding(
                    get: { source.subscribed },
                    set: { newValue in
                        Task {
                            try? await environment.sourceDao.setSubscribed(id: source.id, subscribed: newValue)
                            await load()
                        }
                    }
                ))
                Button {
                    crawl.startCrawl(sources: [source], crawlDaysGap: environment.settings.loadUserSettings().crawlDaysGap)
                } label: {
                    Label("立即抓取", systemImage: "arrow.clockwise")
                }
                .disabled(crawl.progress.running)
            }

            Section("上次运行") {
                if let lastRunAt = source.lastRunAt {
                    LabeledContent("时间", value: DateFormatter.localizedString(
                        from: Date(timeIntervalSince1970: Double(lastRunAt) / 1000),
                        dateStyle: .short, timeStyle: .short
                    ))
                    LabeledContent("入库条数", value: "\(source.lastCount)")
                }
                if let error = source.lastError {
                    Button {
                        showErrorFull = true
                    } label: {
                        Label(error.split(separator: "\n").first.map(String.init) ?? error,
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
            }

            Section {
                ScriptEditorView(
                    text: $scriptText,
                    readOnly: isBuiltIn,
                    onSave: { saveScript() }
                )
                .frame(height: 320)
            } header: {
                Text(isBuiltIn ? "脚本（内置只读）" : "脚本（可编辑）")
            } footer: {
                if !isBuiltIn {
                    Text("保存前会做静态校验，且 @id 必须与数据源一致")
                }
            }

            if !isBuiltIn {
                Section {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("删除该数据源", systemImage: "trash")
                    }
                }
            }
        }
        .alert("上次运行详情", isPresented: $showErrorFull) {
            Button("好") {}
        } message: {
            Text(source.lastError ?? "")
        }
    }

    private func load() async {
        source = try? await environment.sourceDao.getById(id: sourceId)
        guard let source else { return }
        scriptText = Self.readScript(source) ?? ""
        dirty = false
    }

    /// 内置源读 bundle folder reference；侧载源读 Documents/sources/<file>。
    private static func readScript(_ source: NoticeSourceRecord) -> String? {
        guard let file = source.scriptFile else { return nil }
        if source.origin == "builtin",
           let dir = Bundle.main.resourceURL?.appendingPathComponent("Sources") {
            return try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
        }
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sources").appendingPathComponent(file)
        return try? String(contentsOf: path, encoding: .utf8)
    }

    private func saveScript() {
        guard let source, !isBuiltIn else { return }
        let script = scriptText
        guard let manifest = ScriptManifestParser.parse(script) else {
            saveMessage = "保存失败：脚本缺少 @id"
            return
        }
        guard manifest.id == source.id else {
            saveMessage = "保存失败：脚本 @id=\(manifest.id) 与数据源 \(source.id) 不一致"
            return
        }
        let host = JavaScriptHost()
        if let error = host.validate(script: script) {
            saveMessage = "保存失败：\(error)"
            return
        }
        // 落盘 + 更新 manifest 字段（含 scheduleMinutes，对齐 Android saveScript）
        let dirs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: dirs, withIntermediateDirectories: true)
        do {
            try script.write(to: dirs.appendingPathComponent(source.scriptFile ?? "\(source.id).js"),
                             atomically: true, encoding: .utf8)
        } catch {
            saveMessage = "写入失败：\(error.localizedDescription)"
            return
        }
        var updated = source
        updated.version = manifest.version
        updated.domains = JSONStringList(manifest.domains)
        updated.labels = JSONStringList(manifest.labels)
        updated.scheduleMinutes = manifest.scheduleMinutes
        Task {
            try? await environment.sourceDao.upsert(updated)
            await load()
            saveMessage = "已保存（v\(manifest.version)）"
        }
    }

    private func delete() {
        guard let source, !isBuiltIn else { return }
        if let file = source.scriptFile {
            let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("sources").appendingPathComponent(file)
            try? FileManager.default.removeItem(at: path)
        }
        Task {
            try? await environment.sourceDao.deleteById(id: source.id)
            dismiss()
        }
    }
}

/// 脚本编辑器（等宽字体；只读态用于内置源查看）。
struct ScriptEditorView: View {
    @Binding var text: String
    let readOnly: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .disabled(readOnly)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if !readOnly {
                HStack {
                    Spacer()
                    Button("保存") { onSave() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }
}
