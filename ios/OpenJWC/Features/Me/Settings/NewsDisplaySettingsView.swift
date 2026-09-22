import SwiftUI
import OpenJWCCore

/// 资讯显示设置（tasks 7.5）：freshDays / crawlDaysGap 正整数校验即时持久化。
struct NewsDisplaySettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var freshDaysText = ""
    @State private var crawlDaysGapText = ""
    @State private var freshDaysError: String?
    @State private var gapError: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("fresh 高亮窗口")
                    Spacer()
                    TextField("天数", text: $freshDaysText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onSubmit { saveFreshDays() }
                    Text("天").foregroundStyle(.secondary)
                }
                if let freshDaysError {
                    Label(freshDaysError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("发布日期在该窗口内的资讯卡片会用主题色高亮")
            }

            Section {
                HStack {
                    Text("抓取回溯窗口")
                    Spacer()
                    TextField("天数", text: $crawlDaysGapText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onSubmit { saveGap() }
                    Text("天").foregroundStyle(.secondary)
                }
                if let gapError {
                    Label(gapError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("下拉抓取时向上追溯的天数；越大首抓越慢")
            }
        }
        .navigationTitle("显示设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let user = environment.settings.loadUserSettings()
            freshDaysText = String(user.freshDays)
            crawlDaysGapText = String(user.crawlDaysGap)
        }
    }

    private func saveFreshDays() {
        guard let value = Int(freshDaysText), value > 0 else {
            freshDaysError = "请输入正整数"
            return
        }
        freshDaysError = nil
        var user = environment.settings.loadUserSettings()
        if user.freshDays != value {
            user.freshDays = value
            environment.settings.saveUserSettings(user)
        }
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
}
