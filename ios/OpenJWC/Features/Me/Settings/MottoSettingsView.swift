import SwiftUI
import OpenJWCCore

/// 格言设置（对齐 Android MottoSettingsScreen）：在线分支（分类 + 长度）/ 本地分支（text 必填 + author 可空）。
struct MottoSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(MottoStore.self) private var mottoStore
    @Environment(\.dismiss) private var dismiss

    @State private var mottoOnline = true
    @State private var category = ""
    @State private var maxLength = 30
    @State private var mottoText = ""
    @State private var mottoAuthor = ""
    @State private var saved = false
    @State private var showLengthError = false

    private let categories: [(code: String, label: String)] = [
        ("", "不限"),
    ] + HitokotoClient.Category.allCases.map { ($0.rawValue, $0.label) }

    var body: some View {
        Form {
            Section {
                Toggle("在线一言 (hitokoto.cn)", isOn: $mottoOnline)
            } footer: {
                Text("开启后每日自动获取一言；关闭则显示本地格言")
            }

            if mottoOnline {
                Section("一言分类") {
                    Picker("分类", selection: $category) {
                        ForEach(categories, id: \.code) { item in
                            Text(item.label).tag(item.code)
                        }
                    }
                    Stepper(value: $maxLength, in: 1...100) {
                        HStack {
                            Text("最大长度")
                            Spacer()
                            Text("\(maxLength)").foregroundStyle(.secondary)
                        }
                    }
                    if showLengthError {
                        Label("最大长度需在 1–100 之间", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } else {
                Section("本地格言") {
                    TextField("格言正文（必填）", text: $mottoText, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("作者（可空）", text: $mottoAuthor)
                }
            }
        }
        .navigationTitle("格言")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
                    .disabled(!canSave)
            }
        }
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        if mottoOnline {
            return (1...100).contains(maxLength) && hasChanges
        }
        return !mottoText.trimmingCharacters(in: .whitespaces).isEmpty && hasChanges
    }

    private var hasChanges: Bool {
        let user = environment.settings.loadUserSettings()
        if mottoOnline {
            return user.mottoOnline != mottoOnline
                || user.hitokotoCategory != category
                || user.hitokotoMaxLength != maxLength
        }
        return user.mottoOnline != mottoOnline
            || user.mottoText != mottoText
            || user.mottoAuthor != mottoAuthor
    }

    private func load() {
        let user = environment.settings.loadUserSettings()
        mottoOnline = user.mottoOnline
        category = user.hitokotoCategory
        maxLength = user.hitokotoMaxLength
        mottoText = user.mottoText
        mottoAuthor = user.mottoAuthor
        saved = true
    }

    private func save() {
        guard canSave else { return }
        var user = environment.settings.loadUserSettings()
        user.mottoOnline = mottoOnline
        user.hitokotoCategory = category
        user.hitokotoMaxLength = maxLength
        user.mottoText = mottoText.trimmingCharacters(in: .whitespaces)
        user.mottoAuthor = mottoAuthor.trimmingCharacters(in: .whitespaces)
        environment.settings.saveUserSettings(user)
        mottoStore.reload()
        dismiss()
    }
}
