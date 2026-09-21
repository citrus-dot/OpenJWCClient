import SwiftUI

/// 未实现阶段的 tab 占位：仅名称 + 阶段提示，无任何数据层调用（场景「占位 tab 不崩溃」）。
struct PlaceholderTabView: View {
    let title: String
    let systemImage: String
    let phase: Int

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: Text("该模块将在阶段 \(phase) 实现")
            )
        }
    }
}
