import SwiftUI
import OpenJWCCore

/// 设置中心（对齐 Android SettingsScreen 分组；本阶段实现子集，其余随各自阶段）。
struct SettingsHomeView: View {
    var body: some View {
        List {
            Section("对话") {
                NavigationLink {
                    LlmSettingsView()
                } label: {
                    Label("AI 模型设置", systemImage: "cpu")
                }
            }
            Section("资讯") {
                NavigationLink {
                    NewsDisplaySettingsView()
                } label: {
                    Label("显示设置", systemImage: "eye")
                }
                NavigationLink {
                    SourcesEditorView()
                } label: {
                    Label("数据源", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink {
                    MottoSettingsView()
                } label: {
                    Label("格言", systemImage: "text.quote")
                }
            }
            Section("关于") {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("用户协议", systemImage: "doc.plaintext")
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
