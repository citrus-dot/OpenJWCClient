import SwiftUI
import OpenJWCCore

/// 配置档案编辑页（新建/修改共用）：预设回填、Key 存取、测试连接（不要求先保存）。
struct LlmProfileEditView: View {
    @State var profile: LlmProfile
    let isNew: Bool
    /// 保存回调（列表页负责落盘 + 激活约束）。
    let onSave: (LlmProfile) -> Void
    /// 删除回调（按 id；列表页负责删除 Key + 落盘）。
    let onDelete: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var originalName = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testError: String?
    @State private var testTask: Task<Void, Never>?
    @State private var showDeleteConfirm = false

    private let keyStore = LlmKeyStore()

    var body: some View {
        Form {
            Section("名称") {
                TextField("如：DeepSeek 主力 / 备用便宜号", text: $profile.name)
            }

            Section("供应商") {
                Picker("预设", selection: Binding(
                    get: { profile.config.providerId },
                    set: { selectProvider($0) }
                )) {
                    ForEach(LlmPresets.all, id: \.id) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                TextField("接口地址 (baseUrl)", text: $profile.config.baseUrl)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("模型 (model)", text: $profile.config.model)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Section {
                SecureField("API Key", text: $apiKey)
                Button("测试连接") { testConnection() }
                    .disabled(testing || !canTest)
                if testing {
                    HStack { ProgressView(); Text("连接中…") }
                }
                if let testResult {
                    Label(testResult, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                if let testError {
                    Label(testError, systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("Key 保存在本设备（Keychain，不可用时本地加密等效存储）。清空并保存即删除。")
            }
        }
        .navigationTitle(isNew ? "添加配置" : "编辑配置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !isNew {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
                    .disabled(!canSave)
            }
        }
        .confirmationDialog("删除该配置？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                deleteProfile()
            }
        } message: {
            Text("该配置的 API Key 将一并删除，不可恢复")
        }
        .task {
            apiKey = loadKey()
            originalName = profile.name
            // 新建未命名：预填预设名，减少一步输入
            if isNew && profile.name.isEmpty {
                profile.name = LlmPresets.byId(profile.config.providerId).name
            }
        }
    }

    private var canTest: Bool {
        !apiKey.isEmpty && !profile.config.baseUrl.isEmpty && !profile.config.model.isEmpty
    }

    private var canSave: Bool {
        !profile.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadKey() -> String {
        do { return try keyStore.load(for: AgentRuntime.keyAccount(profile.id)) ?? "" } catch { return "" }
    }

    private func selectProvider(_ id: String) {
        let preset = LlmPresets.byId(id)
        profile.config.providerId = id
        if !preset.baseUrl.isEmpty { profile.config.baseUrl = preset.baseUrl }
        if !preset.defaultModel.isEmpty { profile.config.model = preset.defaultModel }
        apiKey = loadKey()
        testResult = nil
        testError = nil
    }

    private func save() {
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        // Key 随档案保存（空串 = 删除）
        if apiKey.isEmpty {
            keyStore.delete(for: AgentRuntime.keyAccount(profile.id))
        } else {
            try? keyStore.save(apiKey, for: AgentRuntime.keyAccount(profile.id))
        }
        onSave(profile)
        dismiss()
    }

    private func deleteProfile() {
        onDelete(profile.id)
        dismiss()
    }

    /// 测试连接：用输入框当前值（不要求先保存），30s 超时，结果截 200 字。
    private func testConnection() {
        testTask?.cancel()
        testResult = nil
        testError = nil
        testing = true
        let probeConfig = profile.config
        let probeKey = apiKey
        testTask = Task {
            do {
                let client = OpenAiCompatibleClient(config: probeConfig, apiKey: probeKey)
                var received = ""
                let stream = client.streamChat(messages: [.user("ping")], tools: [])
                let deadline = Date().addingTimeInterval(30)
                var timedOut = false
                for try await delta in stream {
                    if Task.isCancelled { break }
                    if Date() > deadline { timedOut = true; break }
                    if case .text(let t) = delta { received += t }
                    if case .finished = delta { break }
                }
                let summary = String(received.prefix(200))
                await MainActor.run {
                    testing = false
                    if timedOut {
                        testError = "连接超时（30 秒），请检查接口地址与网络"
                    } else {
                        testResult = summary.isEmpty ? "连接成功（无正文返回）" : "连接成功：\(summary)"
                    }
                }
            } catch is CancellationError {
                await MainActor.run { testing = false }
            } catch let http as LlmHttpException {
                // 按状态码归类（对齐 AgentFailure.fromHttpStatus），给出具体原因与修复指引
                let failure = AgentFailure.fromHttpStatus(http.status)
                await MainActor.run {
                    testing = false
                    testError = "\(failure.summary)（HTTP \(http.status)）"
                }
            } catch let config as LlmConfigException {
                await MainActor.run {
                    testing = false
                    testError = config.message
                }
            } catch {
                await MainActor.run {
                    testing = false
                    testError = error.localizedDescription
                }
            }
        }
    }
}

extension Notification.Name {
    /// 编辑页删除 → 列表页消费（编辑页无法直接改列表状态）。
    static let llmProfileDeleteRequested = Notification.Name("llmProfileDeleteRequested")
}
