import SwiftUI
import MarkdownUI
import OpenJWCCore

/// 关于页（对齐 Android AboutScreen）：名称/版本/描述/GitHub 外链/License。
struct AboutView: View {
    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("OpenJWC").font(.title2.bold())
                    Text("v\(version) (iOS)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section("项目") {
                Text("开源的本地优先校园资讯客户端。抓取脚本在设备端沙箱执行，数据不出本机；AI 功能为可选配置，直接连接你自己的模型服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(destination: URL(string: "https://github.com/OpenJWC/OpenJWCClient")!) {
                    Label("GitHub 仓库", systemImage: "link")
                }
            }

            Section("法律") {
                NavigationLink {
                    PolicyView()
                } label: {
                    Label("用户协议", systemImage: "doc.plaintext")
                }
                LabeledContent("许可证", value: "MIT")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 用户协议页（D-7）：Bundle PrivacyPolicy.md Markdown 渲染 + 降级提示。
struct PolicyView: View {
    @State private var content: String?

    var body: some View {
        Group {
            if let content {
                ScrollView {
                    Markdown(content)
                        .markdownTheme(.policy)
                        .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "协议文档不可用",
                    systemImage: "doc.questionmark",
                    description: Text("资源读取失败，请到项目 README 查看用户协议全文")
                )
            }
        }
        .navigationTitle("用户协议")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let url = Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "md") {
                content = try? String(contentsOf: url, encoding: .utf8)
            }
        }
    }
}

private extension Theme {
    static var policy: Theme {
        Theme.basic.text { FontSize(14) }
    }
}
