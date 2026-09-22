import SwiftUI
import OpenJWCCore

/// LLM 设置页（tasks 7.2 主体提前至 5a，聊天手验依赖）：
/// 10 预设切换即时持久化、Key 存取（清空即删）、测试连接（30s 超时）。
struct LlmSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var config = LlmProviderConfig()
    @State private var apiKey = ""
    @State private var savedSnapshot: (config: LlmProviderConfig, hasKey: Bool) = (LlmProviderConfig(), false)
    @State private var testing = false
    @State private var testResult: String?
    @State private var testError: String?
    @State private var testTask: Task<Void, Never>?

    private let keyStore = LlmKeyStore()
    private static let dailyReportTimes = ["00:00", "06:00", "08:00", "12:00", "18:00", "22:00"]

    var body: some View {
        Form {
            Section("供应商") {
                Picker("预设", selection: Binding(
                    get: { config.providerId },
                    set: { selectProvider($0) }
                )) {
                    ForEach(LlmPresets.all, id: \.id) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                TextField("接口地址 (baseUrl)", text: $config.baseUrl)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("模型 (model)", text: $config.model)
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
                Text("Key 保存在设备 Keychain，不上传。清空并保存即删除。")
            }

            Section("日报") {
                Toggle("自动生成日报", isOn: Binding(
                    get: { environment.settings.loadUserSettings().dailyReportEnabled },
                    set: { enabled in
                        var s = environment.settings.loadUserSettings()
                        s.dailyReportEnabled = enabled
                        environment.settings.saveUserSettings(s)
                    }
                ))
                Picker("生成时间", selection: Binding(
                    get: { normalizedDailyTime() },
                    set: { time in
                        var s = environment.settings.loadUserSettings()
                        s.dailyReportTime = time
                        environment.settings.saveUserSettings(s)
                    }
                )) {
                    ForEach(Self.dailyReportTimes, id: \.self) { time in
                        Text(time).tag(time)
                    }
                }
                .disabled(!environment.settings.loadUserSettings().dailyReportEnabled)
            }
        }
        .navigationTitle("AI 模型设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
                    .disabled(!hasChanges)
            }
        }
        .task {
            config = environment.settings.loadLlmConfig()
            apiKey = loadKey(for: config.providerId)
            savedSnapshot = (config, !apiKey.isEmpty)
        }
    }

    /// Keychain 读取（throws → 空串回退）。
    private func loadKey(for providerId: String) -> String {
        do { return try keyStore.load(for: providerId) ?? "" } catch { return "" }
    }

    private var hasChanges: Bool {
        config != savedSnapshot.config || (!apiKey.isEmpty) != savedSnapshot.hasKey
    }

    private var canTest: Bool {
        !apiKey.isEmpty && !config.baseUrl.isEmpty && !config.model.isEmpty
    }

    /// Android 默认 00:10 不在下拉选项内 → 收敛到最近合法项（roadmap 坑清单）。
    private func normalizedDailyTime() -> String {
        let saved = environment.settings.loadUserSettings().dailyReportTime
        return Self.dailyReportTimes.contains(saved) ? saved : "00:00"
    }

    private func selectProvider(_ id: String) {
        let preset = LlmPresets.byId(id)
        config.providerId = id
        if !preset.baseUrl.isEmpty { config.baseUrl = preset.baseUrl }
        if !preset.defaultModel.isEmpty { config.model = preset.defaultModel }
        apiKey = loadKey(for: id)
        testResult = nil
        testError = nil
        save() // 切换预设立即持久化（对齐 Android）
    }

    private func save() {
        environment.settings.saveLlmConfig(config)
        if apiKey.isEmpty {
            keyStore.delete(for: config.providerId)
        } else {
            try? keyStore.save(apiKey, for: config.providerId)
        }
        savedSnapshot = (config, !apiKey.isEmpty)
    }

    /// 测试连接：用输入框当前值（不要求先保存），30s 超时，结果截 200 字。
    private func testConnection() {
        testTask?.cancel()
        testResult = nil
        testError = nil
        testing = true
        let probeConfig = config
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
            } catch {
                await MainActor.run {
                    testing = false
                    testError = error.localizedDescription
                }
            }
        }
    }
}
