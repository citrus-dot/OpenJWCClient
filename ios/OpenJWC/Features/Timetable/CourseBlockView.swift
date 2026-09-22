import SwiftUI
import OpenJWCCore

/// ARGB Int64 → SwiftUI Color + 课程块配色（D-7 简化决策）：
/// container = 种子色调亮（浅色模式）/调暗（深色模式），content 取对比色。
/// 视觉语义等价 Android CourseColors 的 container/on-container（不移植 MaterialKolor harmonize）。
extension Color {
    init(argb: Int64) {
        self.init(
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255
        )
    }

    static func courseContainer(_ argb: Int64, dark: Bool) -> Color {
        let seed = Color(argb: argb)
        return dark ? seed.mix(with: .black, by: 0.62) : seed.mix(with: .white, by: 0.80)
    }

    static func courseContent(_ argb: Int64, dark: Bool) -> Color {
        let seed = Color(argb: argb)
        return dark ? seed.mix(with: .white, by: 0.70) : seed
    }
}

// MARK: - 课程列（直译 CourseColumnScope 预计算 + 分层渲染）

/// 单天课程列：本周课程全列宽顶层；非本周课程泳道淡显底层。
struct CourseColumnView: View {
    let day: Int
    let courses: [CourseRecord]
    let currentWeek: Int
    let showNonCurrentWeek: Bool
    let periodHeight: CGFloat
    let totalPeriods: Int
    let colWidth: CGFloat
    let colorScheme: ColorScheme
    let onCourseClick: (CourseRecord) -> Void

    var body: some View {
        let dayCourses = courses.filter { $0.dayOfWeek == day }
        // TODO(挂起): 拖拽期间 draggingId 传 nil；恢复时从 f1f597c 取回拖拽链
        let layout = TimetableLayout.columnLayout(
            dayCourses: dayCourses,
            currentWeek: currentWeek,
            showNonCurrentWeek: showNonCurrentWeek,
            draggingId: nil
        )

        ZStack(alignment: .topLeading) {
            // 非本周课程（背景层，重叠并排泳道）
            ForEach(Array(layout.otherSegments.enumerated()), id: \.offset) { _, segment in
                let laneCount = max(segment.laneCount, 1)
                let laneWidth = colWidth / CGFloat(laneCount)
                CourseBlockView(
                    course: segment.course,
                    isCurrentWeek: false,
                    colorScheme: colorScheme,
                    width: laneWidth,
                    height: periodHeight * CGFloat(segment.periods.count),
                    onClick: onCourseClick
                )
                .offset(
                    x: laneWidth * CGFloat(segment.lane),
                    y: periodHeight * CGFloat((segment.periods.first ?? 1) - 1)
                )
                .zIndex(1)
            }

            // 本周课程（顶层，遮盖一切）
            ForEach(layout.thisWeek, id: \.id) { course in
                CourseBlockView(
                    course: course,
                    isCurrentWeek: true,
                    colorScheme: colorScheme,
                    width: colWidth,
                    height: periodHeight * CGFloat(course.duration),
                    onClick: onCourseClick
                )
                .offset(y: periodHeight * CGFloat(course.startPeriod - 1))
                .zIndex(2)
            }
        }
        .frame(width: colWidth, height: periodHeight * CGFloat(totalPeriods), alignment: .topLeading)
    }
}

// MARK: - 课程块（直译 CourseBlock：内容规则/按压缩放）

/// TODO(挂起): 拖拽手势（LongPress sequenced Drag + 浮层联动）已挂起，恢复时从 f1f597c 取回。
struct CourseBlockView: View {
    let course: CourseRecord
    let isCurrentWeek: Bool
    let colorScheme: ColorScheme
    let width: CGFloat
    let height: CGFloat
    let onClick: (CourseRecord) -> Void

    /// 块高 < 80pt 仅课程名（≤2 行），否则课程名（≤3 行）+ 教师 + @地点。
    private var isShort: Bool { height < 80 }

    var body: some View {
        let container = isCurrentWeek
            ? Color.courseContainer(course.color, dark: colorScheme == .dark)
            : Color.secondary.opacity(0.18)
        let content = isCurrentWeek
            ? Color.courseContent(course.color, dark: colorScheme == .dark)
            : Color.secondary.opacity(0.7)

        Button { onClick(course) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(course.name)
                    .font(.callout.weight(isCurrentWeek ? .bold : .regular))
                    .foregroundStyle(content)
                    .lineLimit(isShort ? 2 : 3)
                if !isShort {
                    if !course.teacher.isEmpty {
                        Text(course.teacher)
                            .font(.caption2)
                            .foregroundStyle(content.opacity(0.9))
                            .lineLimit(1)
                    }
                    if !course.location.isEmpty {
                        Text("@\(course.location)")
                            .font(.caption2)
                            .foregroundStyle(content.opacity(0.9))
                            .lineLimit(1)
                    }
                }
            }
            .padding(isShort ? 4 : 8)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(container, in: RoundedRectangle(cornerRadius: 10))
            .padding(2) // 块间隙（间隙透明，Android .padding(2.dp) 在 background 之外）
            .frame(width: width + 4, height: height + 4)
        }
        .buttonStyle(PressScaleButtonStyle())
    }
}

/// 按压缩放 0.97（spring ≈ stiffness 800 / damping 0.5，对齐 Android 块按压反馈）。
struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.5), value: configuration.isPressed)
    }
}
