import SwiftUI

/// Me tab 过渡版：5b 完整实现（Hitokoto 头部 + 设置中心）；当前仅开放 LLM 设置入口（聊天联调依赖）。
struct MePlaceholderView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        LlmSettingsView()
                    } label: {
                        Label("AI 模型设置", systemImage: "cpu")
                    }
                } footer: {
                    Text("聊天与日报依赖此配置（阶段 5 完整设置中心建设中）")
                }
            }
            .navigationTitle("我的")
        }
    }
}
