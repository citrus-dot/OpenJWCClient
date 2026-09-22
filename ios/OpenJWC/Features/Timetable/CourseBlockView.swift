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
    let dragState: TimetableDragState?
    let onCourseClick: (CourseRecord) -> Void
    let onDragStart: (CourseRecord, CGFloat, CGFloat) -> Void
    let onDrag: (CGFloat, CGFloat) -> Void
    let onDragEnd: () -> Void
    let onDragCancel: () -> Void

    var body: some View {
        let dayCourses = courses.filter { $0.dayOfWeek == day }
        let layout = TimetableLayout.columnLayout(
            dayCourses: dayCourses,
            currentWeek: currentWeek,
            showNonCurrentWeek: showNonCurrentWeek,
            draggingId: dragState?.draggingCourse?.id
        )

        ZStack(alignment: .topLeading) {
            // 非本周课程（背景层，重叠并排泳道）
            ForEach(Array(layout.otherSegments.enumerated()), id: \.offset) { _, segment in
                let laneCount = max(segment.laneCount, 1)
                let laneWidth = colWidth / CGFloat(laneCount)
                let isBeingDragged = dragState?.draggingCourse?.id == segment.course.id
                CourseBlockView(
                    course: segment.course,
                    isCurrentWeek: false,
                    colorScheme: colorScheme,
                    width: laneWidth,
                    height: periodHeight * CGFloat(segment.periods.count),
                    dragState: dragState,
                    onDragStart: onDragStart,
                    onDrag: onDrag,
                    onDragEnd: onDragEnd,
                    onDragCancel: onDragCancel,
                    onClick: onCourseClick
                )
                .opacity(isBeingDragged ? 0 : 1)
                .offset(
                    x: laneWidth * CGFloat(segment.lane),
                    y: periodHeight * CGFloat((segment.periods.first ?? 1) - 1)
                )
                .zIndex(1)
            }

            // 本周课程（顶层，遮盖一切）
            ForEach(layout.thisWeek, id: \.id) { course in
                let isBeingDragged = dragState?.draggingCourse?.id == course.id
                CourseBlockView(
                    course: course,
                    isCurrentWeek: true,
                    colorScheme: colorScheme,
                    width: colWidth,
                    height: periodHeight * CGFloat(course.duration),
                    dragState: dragState,
                    onDragStart: onDragStart,
                    onDrag: onDrag,
                    onDragEnd: onDragEnd,
                    onDragCancel: onDragCancel,
                    onClick: onCourseClick
                )
                .opacity(isBeingDragged ? 0 : 1)
                .offset(y: periodHeight * CGFloat(course.startPeriod - 1))
                .zIndex(isBeingDragged ? 0 : 2)
            }
        }
        .frame(width: colWidth, height: periodHeight * CGFloat(totalPeriods), alignment: .topLeading)
    }
}

// MARK: - 课程块（直译 CourseBlock：内容规则/缩放/长按手势）

struct CourseBlockView: View {
    let course: CourseRecord
    let isCurrentWeek: Bool
    let colorScheme: ColorScheme
    var isDragging = false
    var scaleOverride: Float?
    var initialScale: Float = 1
    let width: CGFloat
    let height: CGFloat
    let dragState: TimetableDragState?
    let onDragStart: ((CourseRecord, CGFloat, CGFloat) -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onDragCancel: (() -> Void)?
    let onClick: (CourseRecord) -> Void

    @State private var pressed = false
    @State private var scale: Float

    init(
        course: CourseRecord, isCurrentWeek: Bool, colorScheme: ColorScheme,
        isDragging: Bool = false, scaleOverride: Float? = nil, initialScale: Float = 1,
        width: CGFloat, height: CGFloat, dragState: TimetableDragState?,
        onDragStart: ((CourseRecord, CGFloat, CGFloat) -> Void)?,
        onDrag: ((CGFloat, CGFloat) -> Void)?,
        onDragEnd: (() -> Void)?, onDragCancel: (() -> Void)?,
        onClick: @escaping (CourseRecord) -> Void
    ) {
        self.course = course
        self.isCurrentWeek = isCurrentWeek
        self.colorScheme = colorScheme
        self.isDragging = isDragging
        self.scaleOverride = scaleOverride
        self.initialScale = initialScale
        self.width = width
        self.height = height
        self.dragState = dragState
        self.onDragStart = onDragStart
        self.onDrag = onDrag
        self.onDragEnd = onDragEnd
        self.onDragCancel = onDragCancel
        self.onClick = onClick
        self.scale = initialScale
    }

    private var targetScale: Float {
        if isDragging { return 1.06 }
        if pressed { return 0.97 }
        return 1
    }

    /// 块高 < 80pt 仅课程名（≤2 行），否则课程名（≤3 行）+ 教师 + @地点。
    private var isShort: Bool { height < 80 }

    var body: some View {
        let container = isCurrentWeek
            ? Color.courseContainer(course.color, dark: colorScheme == .dark)
            : Color.secondary.opacity(0.18)
        let content = isCurrentWeek
            ? Color.courseContent(course.color, dark: colorScheme == .dark)
            : Color.secondary.opacity(0.7)

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
        .scaleEffect(CGFloat(scaleOverride ?? scale))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .gesture(dragGesture)
        .onTapGesture { onClick(course) }
        .onChange(of: targetScale) { _, newValue in
            // spring ≈ stiffness 800 / damping 0.5
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) {
                scale = newValue
            }
        }
        .onAppear { scale = targetScale }
    }

    @State private var dragStarted = false
    @State private var lastTranslation: CGSize = .zero

    /// 长按拖动（等价 detectDragGesturesAfterLongPress）：
    /// 长按成立（0.35s 内位移 ≤50pt 宽容 slop）→ onDragStart(块尺寸)；
    /// 拖动 → translation 转增量 onDrag；松手 → onDragEnd。
    /// maximumDistance 50 是灵敏度关键：默认 10 时手指微动即手势失败（表现为"拖不动"）。
    private var dragGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 50)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first(true):
                    if !dragStarted {
                        dragStarted = true
                        lastTranslation = .zero
                        onDragStart?(course, width - 4, height - 4)
                    }
                case .second(true, let drag?):
                    if !dragStarted {
                        dragStarted = true
                        lastTranslation = .zero
                        onDragStart?(course, width - 4, height - 4)
                    }
                    onDrag?(drag.translation.width - lastTranslation.width,
                           drag.translation.height - lastTranslation.height)
                    lastTranslation = drag.translation
                default:
                    break
                }
            }
            .onEnded { value in
                defer {
                    dragStarted = false
                    lastTranslation = .zero
                }
                switch value {
                case .second(true, _):
                    onDragEnd?()
                default:
                    onDragCancel?()
                }
            }
    }
}
