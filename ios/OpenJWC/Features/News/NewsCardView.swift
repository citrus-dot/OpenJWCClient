import SwiftUI
import OpenJWCCore

/// 资讯卡片（对齐 Android NewsCard 字段面）：标题 2 行 / 日期 / 摘要 3 行 / 收藏星标 / fresh 高亮。
struct NewsCardView: View {
    let notice: NoticeRecord
    let isFavorited: Bool
    let freshDays: Int
    let onToggleFavorite: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(notice.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorited ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 15))
                            .foregroundStyle(isFavorited ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFavorited ? "取消收藏" : "收藏")
                }

                Text(notice.publishedDay)
                    .font(.caption)
                    .foregroundStyle(.tint)

                if let content = notice.content, !content.isEmpty {
                    Text(content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cardBackground: some View {
        // D-8：iOS 26 玻璃卡片；18 回退常规材质。fresh 卡片用主色容器（对齐 Android primaryContainer）。
        let fresh = Self.isDateFresh(notice.publishedDay, freshDays: freshDays)
        if #available(iOS 26.0, *) {
            RoundedRectangle(cornerRadius: 20)
                .fill(fresh ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.background.secondary))
                .glassEffect(in: RoundedRectangle(cornerRadius: 20))
        } else {
            RoundedRectangle(cornerRadius: 20)
                .fill(fresh ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.background.secondary))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                )
        }
    }

    /// 场景「fresh 日期高亮」：日期距今 ≤ freshDays（对齐 Android isDateFresh，取 yyyy-MM-dd）。
    static func isDateFresh(_ day: String, freshDays: Int) -> Bool {
        guard freshDays > 0, day.count >= 10 else { return false }
        let text = String(day.prefix(10))
        guard let date = Self.dayFormatter.date(from: text) else { return false }
        let start = Calendar.current.startOfDay(for: date)
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0 <= freshDays
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
