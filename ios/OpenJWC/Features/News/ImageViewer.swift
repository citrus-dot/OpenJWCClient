import SwiftUI

/// 全屏图片查看器（场景「查看图片」）：捏合缩放、拖动查看、分享、失败重试。
struct ImageViewer: View {
    let url: URL
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var retryToken = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AsyncImage(url: cacheBustedURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(zoomGesture.simultaneously(with: panGesture))
                        .onTapGesture(count: 2) { reset() }
                        // 单击退出（仅在未放大时；放大后单击用于收手势）
                        .onTapGesture(count: 1) {
                            if scale == 1 { onClose() }
                        }
                case .failure:
                    failureView
                default:
                    ProgressView().tint(.white)
                }
            }
            .id(retryToken)

            // 顶部控制条：fullScreenCover 内没有 NavigationStack，toolbar 不渲染，
            // 因此用常驻 overlay 按钮保证关闭/分享入口始终可见
            VStack {
                HStack {
                    circleButton("xmark", "关闭") { onClose() }
                    Spacer()
                    ShareLink(item: url) {
                        circleButtonLabel("square.and.arrow.up")
                    }
                    .accessibilityLabel("分享")
                }
                .padding(.horizontal, 20)
                Spacer()
            }
        }
    }

    private func circleButton(_ systemName: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            circleButtonLabel(systemName)
        }
        .accessibilityLabel(label)
    }

    private func circleButtonLabel(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(10)
            .background(.ultraThinMaterial, in: Circle())
    }

    private var cacheBustedURL: URL {
        // 重试时绕过 URL 缓存
        retryToken == 0 ? url : URL(string: url.absoluteString + "#r\(retryToken)") ?? url
    }

    private var failureView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.6))
            Button("重试") {
                retryToken += 1
            }
            .buttonStyle(.bordered)
        }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = max(1, lastScale * value)
            }
            .onEnded { _ in
                lastScale = scale
                if scale == 1 { offset = .zero; lastOffset = .zero }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func reset() {
        withAnimation(.spring(duration: 0.25)) {
            scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
        }
    }
}
