import SwiftUI
import WidgetKit
import OpenJWCCore

// MARK: - Entry 视图（三尺寸，红线 2：containerBackground 必用）

struct CourseWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CourseEntry

    /// 有用户背景图时背景不可移除（对齐 Android 背景始终在；无图默认可移除保 StandBy 资格）。
    private var hasBackgroundImage: Bool {
        WidgetSettingsReader.backgroundImageURL() != nil
    }

    var body: some View {
        // 红线 2：containerBackground(for: .widget) 必用（iOS 17+，否则 StandBy/锁屏渲染异常）。
        // 注：containerBackgroundRemovable 为 WidgetConfiguration 级静态 API（iOS 26 SDK 实测），
        // 无法按背景图动态切换——保留默认可移除（有背景图时桌面正常渲染，仅 StandBy 特殊模式移除）。
        content
            .containerBackground(for: .widget) { backgroundLayer }
            .widgetURL(Self.timetableURL)
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if let url = WidgetSettingsReader.backgroundImageURL(),
           let image = UIImage(contentsOfFile: url.path) {
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .opacity(WidgetSettingsReader.backgroundOpacity())
            }
        } else {
            Color(.systemGray6)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            SmallContent(entry: entry)
        case .systemLarge:
            LargeContent(entry: entry)
        default:
            MediumContent(entry: entry)
        }
    }

    /// 点击深链：进课表 tab（主 app onOpenURL 接收）。
    static let timetableURL = URL(string: "openjwc://timetable")!
}

// MARK: - 头部（今天/明天 · 星期X + 第 N 周）

private struct Header: View {
    let entry: CourseEntry

    var body: some View {
        let weekday = Self.weekdayText(entry.date)
        HStack(alignment: .center) {
            Label(
                entry.state.showsTomorrow ? "明天 · \(weekday)" : "今天 · \(weekday)",
                systemImage: "tablecells"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Spacer()
            if let week = entry.state.weekNumber {
                Text("第 \(week) 周")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
        }
    }

    private static func weekdayText(_ date: Date) -> String {
        let names = ["", "一", "二", "三", "四", "五", "六", "日"]
        let weekday = Calendar.current.component(.weekday, from: date)
        return "星期" + (weekday >= 1 && weekday <= 7 ? names[weekday] : "")
    }
}

// MARK: - 课程卡（Medium/Large 共用：时间列 + 色条 + 课名 + 元数据行 + 倒计时）

private struct CourseCard: View {
    let course: WidgetDisplayState.Course

    private var color: Color {
        Color(ArgbInt: course.color)
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 1) {
                Text(course.startTime)
                Text(course.endTime)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 34, alignment: .center)

            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 3.5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(course.name)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let countdown = course.countdownMinutes {
                        Text("约 \(countdown) 分钟")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                Text("\(course.periodText) | \(course.location) | \(course.teacher)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Medium（对齐 Android 4×2 基准：头部 + 最多 2 门课程卡）

private struct MediumContent: View {
    let entry: CourseEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(entry: entry)
            if entry.state.courses.isEmpty, let message = entry.state.emptyMessage {
                emptyState(message)
            } else {
                ForEach(entry.state.courses, id: \.id) { course in
                    CourseCard(course: course)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Small（头部 + 精简行「时间 课名 教室」）

private struct SmallContent: View {
    let entry: CourseEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(entry: entry)
            if entry.state.courses.isEmpty, let message = entry.state.emptyMessage {
                emptyState(message)
            } else {
                ForEach(entry.state.courses, id: \.id) { course in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(course.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text("\(course.startTime) \(course.location)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
    }
}

// MARK: - Large（Medium 同款卡片 + 剩余课程完整列表，超出空间截断）

private struct LargeContent: View {
    let entry: CourseEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(entry: entry)
            if entry.state.courses.isEmpty, let message = entry.state.emptyMessage {
                emptyState(message)
            } else {
                ForEach(entry.state.courses + entry.state.moreCourses, id: \.id) { course in
                    CourseCard(course: course)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - 空态

private func emptyState(_ message: String) -> some View {
    VStack(spacing: 6) {
        Spacer(minLength: 0)
        Image(systemName: "checkmark.seal")
            .font(.title3)
            .foregroundStyle(.secondary)
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
        Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .center)
}

// MARK: - ARGB Int64 → Color（与 Android Color.toArgb() 同位模式，可能为负）

private extension Color {
    init(ArgbInt value: Int64) {
        let argb = UInt64(bitPattern: value)
        let a = Double((argb >> 24) & 0xFF) / 255.0
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
