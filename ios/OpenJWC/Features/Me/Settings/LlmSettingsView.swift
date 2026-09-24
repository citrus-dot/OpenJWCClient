import SwiftUI
import OpenJWCCore

/// LLM 设置主页：多配置档案列表（激活单选 / 编辑 / 添加 / 删除）。
struct LlmSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var profiles: [LlmProfile] = []
    @State private var editing: LlmProfile?
    @State private var isNew = false
    @State private var deleting: LlmProfile?

    var body: some View {
        Group {
            if profiles.isEmpty {
                emptyState
            } else {
                profileList
            }
        }
        .navigationTitle("AI 模型设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = LlmProfile(name: "", config: LlmProviderConfig())
                    isNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加配置")
            }
        }
        .navigationDestination(item: $editing) { profile in
            LlmProfileEditView(
                profile: profile,
                isNew: isNew,
                onSave: { upsert($0) },
                onDelete: { deleteById($0) }
            )
        }
        .alert("删除配置「\(deleting?.name ?? "")」？", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("删除", role: .destructive) { delete(deleting) }
        } message: {
            Text("该配置的 API Key 将一并删除，不可恢复")
        }
        .task { profiles = environment.settings.loadProfiles() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("尚未配置模型", systemImage: "cpu")
        } description: {
            Text("添加一套供应商配置（含 API Key）后，即可使用对话与日报")
        } actions: {
            Button("添加配置") {
                editing = LlmProfile(name: "", config: LlmProviderConfig())
                isNew = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var profileList: some View {
        List {
            Section {
                ForEach(profiles) { profile in
                    profileRow(profile)
                }
            } footer: {
                Text("点圆点切换当前使用的配置；点名称进入编辑。对话与日报使用「使用中」的配置。")
            }
            Section {
                dailyReportSection
            } header: {
                Text("日报")
            }
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: LlmProfile) -> some View {
        HStack(spacing: 12) {
            // 激活单选圆点（点它 = 启用该配置）
            Button {
                activate(profile)
            } label: {
                Image(systemName: profile.isActive ? "largecircle.fill.circle" : "circle")
                    .font(.body)
                    .foregroundStyle(profile.isActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(profile.isActive ? "当前使用" : "设为当前使用")

            // 点行 = 编辑
            Button {
                isNew = false
                editing = profile
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.name.isEmpty ? "未命名配置" : profile.name)
                            .font(.body.weight(profile.isActive ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        if profile.isActive {
                            Text("使用中")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: Capsule())
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(subtitle(profile))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.borderless)

            Spacer()

            // 编辑入口（与整行点击等价，明确 affordance）
            Button {
                isNew = false
                editing = profile
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleting = profile
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var dailyReportSection: some View {
        Toggle("自动生成日报", isOn: Binding(
            get: { environment.settings.loadUserSettings().dailyReportEnabled },
            set: { enabled in
                var s = environment.settings.loadUserSettings()
                s.dailyReportEnabled = enabled
                environment.settings.saveUserSettings(s)
                // 阶段 7a：变更即同步日报后台任务（开 → 提交；关 → 取消）
                Task { await environment.backgroundTasks.submitDailyReportTask() }
            }
        ))
        Picker("生成时间", selection: Binding(
            get: { normalizedDailyTime() },
            set: { time in
                var s = environment.settings.loadUserSettings()
                s.dailyReportTime = time
                environment.settings.saveUserSettings(s)
                // 阶段 7a：时刻变更 → 以新时刻重提交（earliestBeginDate 更新）
                Task { await environment.backgroundTasks.submitDailyReportTask() }
            }
        )) {
            ForEach(Self.dailyReportTimes, id: \.self) { time in
                Text(time).tag(time)
            }
        }
        .disabled(!environment.settings.loadUserSettings().dailyReportEnabled)
    }

    // MARK: - 操作

    private func subtitle(_ profile: LlmProfile) -> String {
        let preset = LlmPresets.byId(profile.config.providerId).name
        return "\(preset) · \(profile.config.model.isEmpty ? "未填模型" : profile.config.model)"
    }

    private func activate(_ target: LlmProfile) {
        profiles = LlmProfile.normalize(profiles.map {
            var p = $0
            p.isActive = (p.id == target.id)
            return p
        })
        environment.settings.saveProfiles(profiles)
    }

    private func upsert(_ saved: LlmProfile) {
        if let index = profiles.firstIndex(where: { $0.id == saved.id }) {
            profiles[index] = saved
        } else {
            profiles.append(saved)
        }
        profiles = LlmProfile.normalize(profiles)
        environment.settings.saveProfiles(profiles)
    }

    private func delete(_ target: LlmProfile?) {
        guard let target else { return }
        deleteById(target.id)
    }

    private func deleteById(_ id: String) {
        LlmKeyStore().delete(for: AgentRuntime.keyAccount(id))
        profiles.removeAll { $0.id == id }
        profiles = LlmProfile.normalize(profiles)
        environment.settings.saveProfiles(profiles)
    }

    private static let dailyReportTimes = ["00:00", "06:00", "08:00", "12:00", "18:00", "22:00"]

    /// Android 默认 00:10 不在下拉选项内 → 收敛到最近合法项（roadmap 坑清单）。
    private func normalizedDailyTime() -> String {
        let saved = environment.settings.loadUserSettings().dailyReportTime
        return Self.dailyReportTimes.contains(saved) ? saved : "00:00"
    }
}
