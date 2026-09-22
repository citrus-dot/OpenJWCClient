import SwiftUI
import OpenJWCCore

/// 输入区：附件徽标 + TextEditor + 发送/停止一键切换（D-12）。
struct InputBar: View {
    @Binding var showAttachmentSheet: Bool
    @Binding var followBottom: Bool
    @Environment(ChatStore.self) private var chat
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(chat.attachments.enumerated()), id: \.element.id) { index, attachment in
                            HStack(spacing: 4) {
                                Text(attachment.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Button {
                                    chat.removeAttachment(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.tint.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    showAttachmentSheet = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 17))
                        .frame(width: 36, height: 36)
                        .background(.background.secondary, in: Circle())
                }
                .padding(.bottom, 0)
                .accessibilityLabel("引用资讯")

                TextField("输入消息…", text: Binding(
                    get: { chat.inputText },
                    set: { chat.inputText = $0 }
                ), axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
                .focused($focused)
                .onSubmit { submitOrStop() }

                Button {
                    submitOrStop()
                } label: {
                    if chat.isGenerating {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.red)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.tint)
                    }
                }
                .disabled(!chat.isGenerating && chat.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(chat.isGenerating ? "停止" : "发送")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .padding(.top, 6)
        .background(.bar)
    }

    private func submitOrStop() {
        if chat.isGenerating {
            chat.stopGenerating()
        } else {
            Task {
                await chat.sendMessage()
                followBottom = true
            }
        }
    }
}

/// 会话列表抽屉（新建 / 重命名 / 删除确认 / 状态图标）。
struct SessionListView: View {
    @Environment(ChatStore.self) private var chat
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: ChatSessionRecord?
    @State private var renameText = ""
    @State private var deleting: ChatSessionRecord?

    var body: some View {
        @Bindable var chat = chat
        NavigationStack {
            List {
                Button {
                    chat.startNewChat()
                    dismiss()
                } label: {
                    Label("新聊天", systemImage: "plus.bubble")
                }

                ForEach(chat.sessions, id: \.sessionId) { session in
                    sessionRow(session)
                }
            }
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("重命名会话", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("标题", text: $renameText)
                Button("取消", role: .cancel) { renaming = nil }
                Button("确定") {
                    if let target = renaming,
                       !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Task { await chat.renameSession(target.sessionId ?? 0, title: renameText) }
                    }
                    renaming = nil
                }
            }
            .alert("删除会话？", isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let target = deleting {
                        Task { await chat.deleteSession(target.sessionId ?? 0) }
                    }
                    deleting = nil
                }
            } message: {
                Text("会话及其全部消息将被删除，不可恢复")
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: ChatSessionRecord) -> some View {
        let id = session.sessionId ?? 0
        let isCurrent = chat.currentSessionId == id
        Button {
            chat.loadSession(id)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? "未命名会话" : session.title)
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(Self.dateText(session.lastUpdated))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                stateIcon(id)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleting = session
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                renaming = session
                renameText = session.title
            } label: {
                Label("重命名", systemImage: "pencil")
            }
        }
    }

    @ViewBuilder
    private func stateIcon(_ id: Int64) -> some View {
        switch chat.sessionStates[id] {
        case .loading, .generating, .toolCalling:
            ProgressView().controlSize(.mini)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private static func dateText(_ millis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }
}
