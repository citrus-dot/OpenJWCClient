import SwiftUI
import OpenJWCCore

/// 课表 tab 根视图（对齐 Android TimetableView）：顶栏（表名/周胶囊）+ 周翻页 + 网格 + 空态。
struct TimetableRootView: View {
    @Environment(TimetableStore.self) private var store
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            Group {
                if let table = store.currentTable, let config = store.config {
                    pager(table: table, config: config)
                } else {
                    emptyState
                }
            }
            .navigationTitle("课程表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if DEBUG
                // 6a 拖拽手验临时入口：注入示例课程（6b 编辑器到位后移除）
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            let dao = TimetableDao(db: environment.db)
                            guard let table = store.currentTable, let id = table.id else {
                                NSLog("魔棒：无当前课表，忽略")
                                return
                            }
                            let names = [(1, "软件工程"), (4, "数据结构")]
                            for (day, name) in names {
                                do {
                                    let rowId = try await dao.insertCourse(CourseRecord(
                                        id: nil, tableId: id, name: name, teacher: "李老师", location: "机房",
                                        dayOfWeek: day, startPeriod: 3, duration: 2,
                                        color: TimetableJson.deterministicColor(for: name),
                                        weekRule: JSONIntSet(Set(1...16)), note: ""
                                    ))
                                    NSLog("魔棒插入成功: \(name) rowId=\(rowId)")
                                } catch {
                                    NSLog("魔棒插入失败: \(name) \(error)")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                }
                #endif
            }
        }
        .onAppear { store.recomputeCurrentWeek() }
    }

    // MARK: - 周翻页（D-3 双向同步）

    @ViewBuilder
    private func pager(table: TableMetadataRecord, config: SemesterConfig) -> some View {
        TabView(selection: Binding(
            get: { store.currentWeek - 1 },
            set: { store.setWeek(fromPage: $0) }
        )) {
            ForEach(0..<max(config.weeks, 1), id: \.self) { pageIndex in
                weekPage(table: table, config: config, week: pageIndex + 1)
                    .tag(pageIndex)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private func weekPage(table: TableMetadataRecord, config: SemesterConfig, week: Int) -> some View {
        TimetableGridView(
            table: table,
            courses: store.courses,
            currentWeek: week,
            config: config,
            prefs: store.displayPrefs,
            activePeriodIndex: week == store.currentWeek ? store.activePeriodIndex : -1,
            nowMinuteOfDay: store.nowMinuteOfDay,
            dragState: week == store.currentWeek ? store.dragState : nil,
            onCourseClick: { _ in /* 6b: 课程详情 sheet */ },
            onEmptySlotClick: { _, _ in /* 6b: 新建编辑器预填 */ },
            onCourseMove: { course, day, period in
                Task { await store.moveCourse(course, toDay: day, startPeriod: period) }
            }
        )
    }

    // MARK: - 空态引导（场景「空态引导」）

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tablecells")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("暂无课表")
                .font(.headline)
            Text("创建一张空白课表开始；JSON 文件导入随 6b 提供")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("创建空白课表") {
                Task {
                    let service = TimetableService(db: environment.db)
                    _ = try? await service.createTable(TimetableJson.defaultTable())
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 单周网格

/// 单周网格（直译 Android TimetableGrid 几何与分层）：
/// 背景层 → 指示线 → 非本周泳道 → 本周课程 → 拖拽浮层。
struct TimetableGridView: View {
    let table: TableMetadataRecord
    let courses: [CourseRecord]
    let currentWeek: Int
    let config: SemesterConfig
    let prefs: (timeline: Bool, date: Bool, periodTime: Bool, nonCurrentWeek: Bool)
    let activePeriodIndex: Int
    let nowMinuteOfDay: Int
    let dragState: TimetableDragState?
    let onCourseClick: (CourseRecord) -> Void
    let onEmptySlotClick: (Int, Int) -> Void
    let onCourseMove: (CourseRecord, Int, Int) -> Void

    @Environment(\.colorScheme) private var colorScheme

    static let minPeriodHeight: CGFloat = 60
    static let timeLabelWidth: CGFloat = 44
    static let titleHeight: CGFloat = 48

    private var sortedVisibleDays: [Int] {
        config.visibleDays.sorted()
    }

    var body: some View {
        GeometryReader { proxy in
            let gridHeight = proxy.size.height - Self.titleHeight
            let periodHeight = max(Self.minPeriodHeight, gridHeight / CGFloat(max(config.periods.count, 1)))
            let dayCount = sortedVisibleDays.count
            let colWidth = dayCount > 0 ? (proxy.size.width - Self.timeLabelWidth) / CGFloat(dayCount) : 0

            ScrollView {
                VStack(spacing: 0) {
                    TimetableHeaderRow(
                        currentWeek: currentWeek,
                        startDate: config.startDate,
                        sortedVisibleDays: sortedVisibleDays,
                        timeLabelWidth: Self.timeLabelWidth,
                        titleHeight: Self.titleHeight,
                        showDate: prefs.date
                    )
                    gridBody(periodHeight: periodHeight, colWidth: colWidth)
                }
            }
        }
    }

    @ViewBuilder
    private func gridBody(periodHeight: CGFloat, colWidth: CGFloat) -> some View {
        let totalWidth = colWidth * CGFloat(sortedVisibleDays.count) + Self.timeLabelWidth
        ZStack(alignment: .topLeading) {
            GridBackgroundLayer(
                config: config,
                sortedVisibleDays: sortedVisibleDays,
                periodHeight: periodHeight,
                timeLabelWidth: Self.timeLabelWidth,
                activePeriodIndex: activePeriodIndex,
                showPeriodTime: prefs.periodTime,
                totalWidth: totalWidth
            )

            if prefs.timeline {
                TimeIndicatorLine(
                    periods: config.periods,
                    periodHeight: periodHeight,
                    timeLabelWidth: Self.timeLabelWidth,
                    totalWidth: totalWidth,
                    nowMinuteOfDay: nowMinuteOfDay
                )
            }

            HStack(spacing: 0) {
                Color.clear.frame(width: Self.timeLabelWidth, height: periodHeight * CGFloat(config.periods.count))
                ForEach(sortedVisibleDays, id: \.self) { day in
                    CourseColumnView(
                        day: day,
                        courses: courses,
                        currentWeek: currentWeek,
                        showNonCurrentWeek: prefs.nonCurrentWeek,
                        periodHeight: periodHeight,
                        totalPeriods: config.periods.count,
                        colWidth: colWidth,
                        colorScheme: colorScheme,
                        dragState: dragState,
                        onCourseClick: onCourseClick,
                        onDragStart: { course, width, height in
                            dragStart(course, width: width, height: height,
                                      colWidth: colWidth, periodHeight: periodHeight)
                        },
                        onDrag: { dx, dy in dragState?.drag(dx: dx, dy: dy) },
                        onDragEnd: { dragEnd(colWidth: colWidth, periodHeight: periodHeight) },
                        onDragCancel: { dragCancel() }
                    )
                }
            }

            dragOverlay(periodHeight: periodHeight, colWidth: colWidth)
        }
        .onChange(of: courses) { _, _ in
            // 数据反映落位结果 → 撤浮层（1s 兜底在 reflectAndDismiss 内）
            reflectAndDismiss()
        }
    }

    // MARK: - 拖拽链路（D-2，直译 TimetableGrid.kt:139-223）

    /// 待反映的落位（数据反映/1s 兜底后撤浮层）。
    private struct PendingMove: Equatable {
        var courseId: Int64
        var day: Int
        var period: Int
    }

    @State private var pendingMove: PendingMove?
    @State private var lastDropped: (id: Int64, size: CGSize)?
    @State private var settleTask: Task<Void, Never>?
    @State private var overlaySize: CGSize?
    @State private var fallbackTask: Task<Void, Never>?

    private func courseTopLeft(_ course: CourseRecord, colWidth: CGFloat, periodHeight: CGFloat) -> CGPoint {
        let dayIndex = sortedVisibleDays.firstIndex(of: course.dayOfWeek) ?? 0
        let periodIndex = max(config.periods.firstIndex { $0.index == course.startPeriod } ?? 0, 0)
        return CGPoint(
            x: Self.timeLabelWidth + CGFloat(dayIndex) * colWidth,
            y: periodHeight * CGFloat(periodIndex)
        )
    }

    private func dragStart(_ course: CourseRecord, width: CGFloat, height: CGFloat,
                           colWidth: CGFloat, periodHeight: CGFloat) {
        guard let dragState else { return }
        lastDropped = nil
        overlaySize = CGSize(width: width, height: height)
        dragState.start(
            course: course,
            blockTopLeft: courseTopLeft(course, colWidth: colWidth, periodHeight: periodHeight),
            width: width, height: height
        )
        // 浮层从原尺寸 spring 长到整列 × 全课高（对齐 spring(700f, 0.85f)）
        let target = CGSize(width: colWidth, height: periodHeight * CGFloat(course.duration))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            overlaySize = target
        }
    }

    private func dragEnd(colWidth: CGFloat, periodHeight: CGFloat) {
        guard let dragState, let course = dragState.draggingCourse else {
            dragState?.reset()
            return
        }
        let target = TimetableLayout.resolveDropTarget(
            course: course,
            dragPositionX: dragState.dragPosition.x,
            dragPositionY: dragState.dragPosition.y,
            colWidth: colWidth,
            timeLabelWidth: Self.timeLabelWidth,
            periodHeight: periodHeight,
            sortedVisibleDays: sortedVisibleDays,
            periods: config.periods,
            courses: courses
        )
        if let target,
           target.dayOfWeek != course.dayOfWeek || target.startPeriod != course.startPeriod {
            // 有效落位：220ms 落位动画 → 提交数据 → 浮层保留至观察反映（1s 兜底）
            var moved = course
            moved.dayOfWeek = target.dayOfWeek
            moved.startPeriod = target.startPeriod
            let targetTopLeft = courseTopLeft(moved, colWidth: colWidth, periodHeight: periodHeight)
            let state = dragState
            settleTask?.cancel()
            settleTask = Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.22)) {
                    state.moveTo(targetTopLeft)
                    state.settleScale = 1.00
                }
                try? await Task.sleep(for: .milliseconds(230))
                guard !Task.isCancelled else { return }
                onCourseMove(course, target.dayOfWeek, target.startPeriod)
                lastDropped = (course.id ?? 0, CGSize(width: colWidth, height: periodHeight * CGFloat(course.duration)))
                pendingMove = PendingMove(courseId: course.id ?? 0, day: target.dayOfWeek, period: target.startPeriod)
            }
        } else {
            snapBack()
        }
    }

    private func dragCancel() {
        guard let dragState else { return }
        snapBack(from: dragState.dragPosition, to: dragState.originalPosition)
    }

    private func snapBack(from: CGPoint? = nil, to: CGPoint? = nil) {
        guard let dragState else { return }
        let start = from ?? dragState.dragPosition
        let end = to ?? dragState.originalPosition
        let state = dragState
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.22)) {
                state.moveTo(end)
                state.settleScale = 1.00
            }
            try? await Task.sleep(for: .milliseconds(230))
            guard !Task.isCancelled else { return }
            state.reset()
        }
    }

    /// 数据反映落位结果后撤浮层（由 courses onChange 驱动；1s 兜底强制撤除）。
    private func reflectAndDismiss() {
        guard let pending = pendingMove, let dragState else { return }
        let reflected = courses.contains {
            $0.id == pending.courseId && $0.dayOfWeek == pending.day && $0.startPeriod == pending.period
        }
        if reflected {
            dragState.reset()
            pendingMove = nil
            overlaySize = nil
            return
        }
        if fallbackTask == nil {
            let snapshot = pending
            fallbackTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                fallbackTask = nil
                guard pendingMove == snapshot else { return }
                dragState.reset()
                pendingMove = nil
                overlaySize = nil
            }
        }
    }

    @ViewBuilder
    private func dragOverlay(periodHeight: CGFloat, colWidth: CGFloat) -> some View {
        if let dragState, let course = dragState.draggingCourse {
            let size = overlaySize ?? CGSize(width: dragState.startWidth, height: dragState.startHeight)
            CourseBlockView(
                course: course,
                isCurrentWeek: course.weekRule.value.contains(currentWeek),
                colorScheme: colorScheme,
                isDragging: true,
                scaleOverride: dragState.settleScale,
                width: size.width,
                height: size.height,
                dragState: dragState,
                onDragStart: nil,
                onDrag: nil,
                onDragEnd: nil,
                onDragCancel: nil,
                onClick: { _ in }
            )
            .offset(x: dragState.dragPosition.x, y: dragState.dragPosition.y)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4) // 拖起视觉反馈
            .zIndex(10)
        }
    }
}
