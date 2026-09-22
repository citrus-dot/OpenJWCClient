import SwiftUI
import OpenJWCCore

/// 来源编辑器（对齐 Android SourcesScreen）：
/// 列表（订阅态/本地条数/上次运行摘要）+ crawlDaysGap + 导入/全部抓取/清空缓存。
struct SourcesEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ReactiveStore.self) private var reactive
    @Environment(CrawlCoordinator.self) private var crawl

    @State private var counts: [String: Int] = [:]
    @State private var crawlDaysGapText = ""
    @State private var gapError: String?
    @State private var confirmClear = false
    @State private var fileImporterShown = false
    @State private var importMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(reactive.sources, id: \.id) { source in
                    NavigationLink {
                        SourceDetailView(sourceId: source.id)
                    } label: {
                        sourceRow(source)
                    }
                }
            } header: {
                Text("全部数据源（\(reactive.sources.count)）")
            } footer: {
                Text("点击进入详情：订阅开关 / 立即抓取 / 脚本查看编辑")
            }

            Section("抓取") {
                HStack {
                    Text("回溯天数")
                    Spacer()
                    TextField("天数", text: $crawlDaysGapText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onSubmit { saveGap() }
                }
                if let gapError {
                    Label(gapError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button {
                    fileImporterShown = true
                } label: {
                    Label("导入脚本 (.js)", systemImage: "square.and.arrow.down")
                }
                Button {
                    startCrawlAll()
                } label: {
                    Label(
                        crawl.progress.running ? "抓取中…" : "抓取全部已订阅",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(crawl.progress.running || reactive.sources.isEmpty)
            }

            Section("存储") {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Text("清空资讯缓存（\(reactive.noticeCount) 条）")
                }
            }
        }
        .navigationTitle("数据源")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadCounts() }
        .onAppear { crawlDaysGapText = String(environment.settings.loadUserSettings().crawlDaysGap) }
        .onChange(of: reactive.noticeCount) { _, _ in
            Task { await loadCounts() }
        }
        .confirmationDialog("清空全部资讯缓存？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                Task {
                    try? await environment.noticeDao.clearAll()
                    await loadCounts()
                }
            }
        } message: {
            Text("收藏与资讯数据将被清空，重新下拉抓取即可恢复语料")
        }
        .fileImporter(
            isPresented: $fileImporterShown,
            allowedContentTypes: [.data, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            importScript(result)
        }
        .alert("导入结果", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button("好") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: NoticeSourceRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.subheadline.weight(source.subscribed ? .semibold : .regular))
                    .foregroundStyle(source.subscribed ? .primary : .secondary)
                Text(describe(source))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func describe(_ source: NoticeSourceRecord) -> String {
        var parts = [source.id, "本地 \(counts[source.id] ?? 0) 条",
                     source.subscribed ? "已订阅" : "未订阅"]
        if let lastRunAt = source.lastRunAt {
            let text = DateFormatter.localizedString(
                from: Date(timeIntervalSince1970: Double(lastRunAt) / 1000),
                dateStyle: .short, timeStyle: .short
            )
            parts.append(text)
        }
        if let error = source.lastError, let first = error.split(separator: "\n").first {
            parts.append(String(first))
        }
        return parts.joined(separator: " · ")
    }

    private func loadCounts() async {
        var result: [String: Int] = [:]
        for source in reactive.sources {
            result[source.id] = (try? await environment.noticeDao.countBySource(sourceId: source.id)) ?? 0
        }
        counts = result
    }

    private func saveGap() {
        guard let value = Int(crawlDaysGapText), value > 0 else {
            gapError = "请输入正整数"
            return
        }
        gapError = nil
        var user = environment.settings.loadUserSettings()
        if user.crawlDaysGap != value {
            user.crawlDaysGap = value
            environment.settings.saveUserSettings(user)
        }
    }

    private func startCrawlAll() {
        crawl.startCrawl(
            sources: reactive.sources.filter(\.subscribed),
            crawlDaysGap: environment.settings.loadUserSettings().crawlDaysGap
        )
    }

    /// 导入脚本：读取 → 静态校验 → 缺 @id 拒绝 → 注册（新源默认订阅）。
    private func importScript(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let script = try String(contentsOf: url, encoding: .utf8)
            guard let manifest = ScriptManifestParser.parse(script) else {
                importMessage = "导入失败：脚本缺少 @id 声明"
                return
            }
            // 静态校验
            let host = JavaScriptHost()
            if let error = host.validate(script: script) {
                importMessage = "导入失败：\(error)"
                return
            }
            // 落盘到 Documents/sources/<id>.js + upsert（sideload）
            Task {
                let dirs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("sources", isDirectory: true)
                try? FileManager.default.createDirectory(at: dirs, withIntermediateDirectories: true)
                try script.write(to: dirs.appendingPathComponent("\(manifest.id).js"), atomically: true, encoding: .utf8)
                let dao = SourceDao(db: environment.db)
                let existing = try? await dao.getById(id: manifest.id)
                try await dao.upsert(NoticeSourceRecord(
                    id: manifest.id,
                    name: manifest.name,
                    version: manifest.version,
                    origin: "sideload",
                    scriptFile: "\(manifest.id).js",
                    domains: JSONStringList(manifest.domains),
                    labels: JSONStringList(manifest.labels),
                    scheduleMinutes: manifest.scheduleMinutes,
                    subscribed: existing?.subscribed ?? true,
                    lastRunAt: existing?.lastRunAt,
                    lastCount: existing?.lastCount ?? 0,
                    lastError: existing?.lastError
                ))
                await loadCounts()
                importMessage = "已导入数据源：\(manifest.name)（v\(manifest.version)）"
            }
        } catch {
            importMessage = "读取文件失败：\(error.localizedDescription)"
        }
    }
}
