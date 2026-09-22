import SwiftUI
import OpenJWCCore

/// 工具活动折叠容器（D-13，对齐 Claude thinking 展示模式）：
/// 生成中自动展开 + 具体动作；结束收起为「已使用 N 个工具 · X 秒」摘要行。
struct ToolActivitySection: View {
    let calls: [ChatToolCallRecord]
    let running: Bool

    @State private var expanded: Bool?
    @State private var expandedSummaries: Set<Int64> = []

    private var isExpanded: Bool { expanded ?? running }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // 箭头旋转 + 项目展开均走 spring（D-13 灵动弹性）
                withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                    expanded = !isExpanded
                }
            } label: {
                HStack(spacing: 6) {
                    // 单一箭头旋转：向右 →(90°)→ 向下，收起反向转回
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    if running, let current = calls.last(where: { $0.status == "running" }) {
                        ProgressView().controlSize(.mini)
                        Text("正在\(AgentTools.displayName(current.name))…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(summaryLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(calls, id: \.id) { call in
                        toolRow(call)
                    }
                }
                .padding(.leading, 14)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var summaryLine: String {
        let totalMs = calls.compactMap(\.durationMs).reduce(0, +)
        let seconds = totalMs >= 1000 ? " · \(totalMs / 1000) 秒" : ""
        return "已使用 \(calls.count) 个工具\(seconds)"
    }

    /// 逐卡详情：状态图标 / 展示名 / summary 折叠 / 耗时 / read_notice 深链。
    @ViewBuilder
    private func toolRow(_ call: ChatToolCallRecord) -> some View {
        let id = call.id ?? 0
        let isSummaryExpanded = expandedSummaries.contains(id)
        HStack(alignment: .top, spacing: 6) {
            statusIcon(call.status)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(AgentTools.displayName(call.name))
                        .font(.caption.weight(.medium))
                    if let ms = call.durationMs {
                        Text("\(ms)ms")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if call.status == "failed" {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                if !call.summary.isEmpty {
                    if isSummaryExpanded {
                        Text(call.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        Button("收起") {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                _ = expandedSummaries.remove(id)
                            }
                        }
                        .font(.caption2)
                    } else {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                _ = expandedSummaries.insert(id)
                            }
                        } label: {
                            Text(call.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer()
            if call.name == AgentTools.toolRead, let targetId = call.targetId {
                OpenNoticeButton(targetId: targetId)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(_ status: String) -> some View {
        switch status {
        case "completed":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "failed":
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        default:
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
    }
}

/// read_notice 工具卡跳转按钮（预取 notice 再 push，对齐 Android 预解析）。
struct OpenNoticeButton: View {
    let targetId: String
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @State private var notice: NoticeRecord?

    var body: some View {
        Button {
            if notice != nil {
                router.selectedTab = .news
                router.newsPath.append(targetId)
            }
        } label: {
            Image(systemName: "arrow.up.right.square")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(notice == nil)
        .task {
            notice = try? await environment.noticeDao.findById(id: targetId)
        }
    }
}
