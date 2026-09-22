import SwiftUI
import MarkdownUI

/// 全 app 统一 Markdown 主题（D-3）：聊天气泡 / 资讯详情 / 日报 / 协议页共用。
/// 设计基调：随系统配色、紧凑行距、代码块圆角卡片、引用竖线、标题层级分明。
/// API 已对照 MarkdownUI 2.4 源码（无 LineHeight/StrokeColor，表格用 View 扩展）。
/// @MainActor：块样式闭包在视图构建期（主线程）调用，闭包继承隔离满足 Swift 6 检查。
@MainActor
extension Theme {
    /// 聊天气泡版（字号略小、段距紧凑）。
    static var chat: Theme {
        markdownTheme(bodySize: 14, headingSpacing: 6)
    }

    /// 阅读版（详情/日报/协议，字号 15、行距宽松）。
    static var reading: Theme {
        markdownTheme(bodySize: 15, headingSpacing: 10)
    }

    private static func markdownTheme(bodySize: CGFloat, headingSpacing: CGFloat) -> Theme {
        Theme.basic
            .text {
                FontSize(bodySize)
            }
            .paragraph { configuration in
                configuration.label
                    .lineSpacing(bodySize * 0.4)
                    .padding(.vertical, 1)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: headingSpacing + 4, bottom: 4)
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(bodySize * 1.35)
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: headingSpacing, bottom: 3)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.2)
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: headingSpacing, bottom: 2)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.08)
                    }
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(bodySize * 0.9)
                BackgroundColor(Color(.systemFill).opacity(0.6))
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .font(.system(size: bodySize * 0.88, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(minWidth: 560, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                .markdownMargin(top: 8, bottom: 8)
            }
            .blockquote { configuration in
                configuration.label
                    .padding(.leading, 12)
                    .padding(.vertical, 2)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.5))
                            .frame(width: 3)
                    }
                    .foregroundStyle(.secondary)
                    .markdownMargin(top: 6, bottom: 6)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .table { configuration in
                configuration.label
                    .font(.system(size: bodySize * 0.92))
                    .markdownTableBorderStyle(
                        TableBorderStyle(.allBorders, color: Color(.separator))
                    )
                    .padding(1)
                    .background(Color(.systemGray6).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .markdownMargin(top: 8, bottom: 8)
            }
            .link {
                ForegroundColor(Color.accentColor)
                UnderlineStyle(.single)
            }
            .taskListMarker { configuration in
                Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                    .foregroundStyle(Color.accentColor)
            }
    }
}
