import SwiftUI
import MarkdownUI
import OpenJWCCore

/// 聊天 tab 根视图（D-14）：iPhone 抽屉 / 宽屏 NavigationSplitView 分栏。
struct ChatRootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ChatStore.self) private var chat
    @State private var showSessions = false

    var body: some View {
        NavigationStack {
            ChatView(showSessions: $showSessions)
        }
        .sheet(isPresented: $showSessions) {
            SessionListView()
                .presentationDetents([.medium, .large])
        }
    }
}

/// 消息流 + 输入区。
struct ChatView: View {
    @Binding var showSessions: Bool
    @Environment(ChatStore.self) private var chat
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL

    @State private var showAttachmentSheet = false
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    /// 三态滚动：用户上滑即停跟。
    @State private var followBottom = true

    var body: some View {
        VStack(spacing: 0) {
            messageList
            InputBar(
                showAttachmentSheet: $showAttachmentSheet,
                followBottom: $followBottom
            )
        }
        .navigationTitle(chat.currentSessionTitle ?? "新聊天")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSessions = true } label: {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel("会话列表")
            }
        }
        .sheet(isPresented: $showAttachmentSheet) {
            AttachmentSheet { attachment in
                chat.addAttachment(attachment)
            }
        }
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if chat.turns.isEmpty && chat.streamingText.isEmpty {
                    emptyState
                }
                ForEach(chat.turns, id: \.message.messageId) { turn in
                    TurnView(turn: turn)
                }
                // 流式中的临时气泡（完成即被观察刷新的终态行取代）
                if chat.isGenerating {
                    streamingBubble
                }
                if let failed = chat.failedTurn {
                    RetryRow(failed: failed)
                }
                Color.clear.frame(height: 4).id("bottom-anchor")
            }
            .padding(12)
        }
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            // 距底距离（< 80 视为贴底跟随）
            let bottom = geometry.contentSize.height - geometry.containerSize.height
            return bottom - (geometry.contentOffset.y + geometry.contentInsets.bottom)
        } action: { _, distanceToBottom in
            followBottom = distanceToBottom < 80
        }
        .onChange(of: chat.streamingText) { _, _ in
            if followBottom {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: chat.turns.count) { _, _ in
            if followBottom {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .scrollPosition($scrollPosition)
        .overlay(alignment: .bottomTrailing) {
            if !followBottom {
                Button {
                    followBottom = true
                    scrollPosition.scrollTo(edge: .bottom)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.tint, .background)
                }
                .padding(16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("和本地助手聊聊你的资讯")
                .font(.headline)
            Text("可引用资讯附件，助手会用本地检索工具回答")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }

    /// 流式临时气泡：纯 Text（D-11 两阶段渲染第一阶段）。
    private var streamingBubble: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Text(chat.streamingText.isEmpty ? "…" : chat.streamingText)
                .font(.subheadline)
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
            ProgressView().controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一轮 = 工具活动区（若有）+ 气泡。
private struct TurnView: View {
    let turn: ChatTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !turn.toolCalls.isEmpty {
                ToolActivitySection(calls: turn.toolCalls, running: turn.message.status == .running)
            }
            MessageBubble(record: turn.message)
        }
    }
}

/// 消息气泡（对齐 Android MessageBubble 字段面）。
struct MessageBubble: View {
    let record: ChatMessageRecord

    var body: some View {
        if record.role == .user {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(Array(record.attachmentTitles.value.enumerated()), id: \.offset) { _, title in
                    Label(title, systemImage: "paperclip")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                Text(record.text)
                    .font(.subheadline)
                    .padding(12)
                    .background(.tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 18))
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.85, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            assistantBody
                .frame(maxWidth: UIScreen.main.bounds.width * 0.85, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var assistantBody: some View {
        switch record.status {
        case .running:
            // 占位行：流式正文由 ChatView 的 streamingBubble 承担
            EmptyView()
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                if !record.text.isEmpty {
                    Text(record.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Label(failureSummary, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        default:
            // D-11 第二阶段：完成后一次性 Markdown 渲染
            Markdown(record.text.isEmpty ? "_(空回复)_" : record.text)
                .markdownTheme(.chat)
        }
    }

    private var failureSummary: String {
        if let code = record.errorCode,
           let failure = AgentFailure(rawValue: code) {
            return failure.summary
        }
        return record.errorCode ?? "问答未完成"
    }
}

/// 重试行（失败与停止共用；固定在最后一条用户消息之后）。
struct RetryRow: View {
    let failed: ChatStore.FailedTurn
    @Environment(ChatStore.self) private var chat

    var body: some View {
        HStack(spacing: 10) {
            Label(failed.summary, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
            Spacer()
            Button("重试") {
                Task { await chat.retryLastMessage() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 聊天气泡 Markdown 主题（紧凑版）。
private extension Theme {
    static var chat: Theme {
        Theme.basic.text { FontSize(14) }
    }
}
