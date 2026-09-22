import SwiftUI
import OpenJWCCore
import UniformTypeIdentifiers

/// 课程编辑器呈现上下文（新建可带空槽预填天/节）。
enum EditCourseContext: Identifiable {
    case new(day: Int, startPeriod: Int)
    case edit(CourseRecord)

    var id: String {
        switch self {
        case .new(let day, let period): return "new-\(day)-\(period)"
        case .edit(let course): return "edit-\(course.id ?? 0)"
        }
    }
}

/// 课表 tab 的 sheet 队列（同一时刻最多一张）。
enum TimetableSheet: Identifiable {
    case tableSelect
    case tableConfig(TableMetadataRecord)
    case newTable
    case importPreview(TimetableJson.ParseResult)
    case editCourse(EditCourseContext)
    case courseDetail(CourseRecord, currentWeek: Int)

    var id: String {
        switch self {
        case .tableSelect: return "tableSelect"
        case .tableConfig: return "tableConfig"
        case .newTable: return "newTable"
        case .importPreview: return "importPreview"
        case .editCourse(let ctx): return "edit-\(ctx.id)"
        case .courseDetail(let course, _): return "detail-\(course.id ?? 0)"
        }
    }
}

/// 课表 tab 根视图（对齐 Android TimetableView）：顶栏（表名入口/管理菜单）+ 周翻页 + 网格 + 空态。
struct TimetableRootView: View {
    @Environment(TimetableStore.self) private var store
    @Environment(AppEnvironment.self) private var environment

    @State private var sheet: TimetableSheet?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument: JsonTextDocument?
    @State private var confirmDeleteTable = false
    @State private var alertText: String?

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
                if let table = store.currentTable {
                    // 顶栏课表名 → 表选择入口（spec：周切换与当前周）
                    ToolbarItem(placement: .principal) {
                        Button {
                            sheet = .tableSelect
                        } label: {
                            HStack(spacing: 4) {
                                Text(table.tableName)
                                    .font(.headline)
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.semibold))
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        TimetableMenu(
                            onTableSelect: { sheet = .tableSelect },
                            onTableConfig: {
                                if let table = store.currentTable { sheet = .tableConfig(table) }
                            },
                            onAddCourse: {
                                sheet = .editCourse(.new(day: 1, startPeriod: 1))
                            },
                            onExport: { startExport() },
                            onImport: { showImporter = true },
                            onCreateTable: { sheet = .newTable },
                            onDeleteTable: { confirmDeleteTable = true }
                        )
                    }
                }
            }
        }
        .onAppear {
            store.reloadPrefs()
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .tableSelect:
                TableSelectSheet(
                    tables: store.snapshot.tables,
                    currentId: store.currentTable?.id,
                    onSelect: { table in
                        Task {
                            try? await TimetableService(db: environment.db).switchTable(tableId: table.id ?? 0)
                        }
                        sheet = nil
                    },
                    onCreate: { sheet = .newTable },
                    onParsed: { sheet = .importPreview($0) }
                )
            case .tableConfig(let table):
                TableConfigSheet(
                    mode: .edit(table),
                    coursesInUse: store.courses
                )
            case .newTable:
                TableConfigSheet(mode: .create, coursesInUse: [])
            case .importPreview(let result):
                TableConfigSheet(
                    mode: .importPreview(result),
                    coursesInUse: result.courses
                )
            case .editCourse(let ctx):
                if let table = store.currentTable, let config = store.config {
                    EditCourseSheet(
                        table: table,
                        config: config,
                        courses: store.courses,
                        context: ctx
                    )
                }
            case .courseDetail(let course, let week):
                CourseDetailSheet(
                    course: course,
                    currentWeek: week,
                    totalWeeks: store.config?.weeks ?? 16,
                    onEdit: {
                        sheet = .editCourse(.edit(course))
                    },
                    onDelete: {
                        if let id = course.id {
                            Task { try? await TimetableService(db: environment.db).removeCourse(courseId: id) }
                        }
                        sheet = nil
                    }
                )
            }
        }
        .confirmationDialog(
            "删除当前课表", isPresented: $confirmDeleteTable, titleVisibility: .visible
        ) {
            Button("删除「\(store.currentTable?.tableName ?? "")」", role: .destructive) {
                deleteCurrentTable()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该课表及其全部课程将被删除；若还有其它课表会自动切换到剩余第一张。")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            handleImportResult(result)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: ExportNaming.sanitizedFileName(store.currentTable?.tableName ?? "")
        ) { _ in }
        .alert(
            "提示",
            isPresented: Binding(
                get: { alertText != nil },
                set: { if !$0 { alertText = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
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
            onCourseClick: { course in
                sheet = .courseDetail(course, currentWeek: week)
            },
            onEmptySlotClick: { day, period in
                sheet = .editCourse(.new(day: day, startPeriod: period))
            }
        )
    }

    // MARK: - 导出 / 导入 / 删表

    private func startExport() {
        guard let table = store.currentTable else { return }
        guard let json = TimetableJson.buildExport(table: table, courses: store.courses) else {
            alertText = "当前课表没有课程，无法导出。"
            return
        }
        exportDocument = JsonTextDocument(text: json)
        showExporter = true
    }

    private func handleImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            alertText = "读取文件失败：\(error.localizedDescription)"
        case .success(let url):
            do {
                sheet = .importPreview(try TimetableImport.parseFile(at: url))
            } catch let error as TimetableJson.ParseError {
                alertText = error.errorDescription
            } catch {
                alertText = "读取文件失败：\(error.localizedDescription)"
            }
        }
    }

    private func deleteCurrentTable() {
        guard let id = store.currentTable?.id else { return }
        Task {
            try? await TimetableService(db: environment.db).deleteTable(tableId: id)
        }
    }

    // MARK: - 空态引导（场景「空态引导」：导入 + 新建两入口）

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tablecells")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("暂无课表")
                .font(.headline)
            Text("创建一张空白课表，或从 JSON 文件导入")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                Button {
                    sheet = .newTable
                } label: {
                    Label("新建空白课表", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 单周网格

/// 单周网格（直译 Android TimetableGrid 几何与分层）：
/// 背景层 → 指示线 → 非本周泳道 → 本周课程（空槽 tap 统一层定位）。
struct TimetableGridView: View {
    let table: TableMetadataRecord
    let courses: [CourseRecord]
    let currentWeek: Int
    let config: SemesterConfig
    let prefs: (timeline: Bool, date: Bool, periodTime: Bool, nonCurrentWeek: Bool)
    let activePeriodIndex: Int
    let nowMinuteOfDay: Int
    let onCourseClick: (CourseRecord) -> Void
    let onEmptySlotClick: (Int, Int) -> Void

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
                        onCourseClick: onCourseClick
                    )
                }
            }
        }
        // 空槽 tap 定位（直译 GridBackgroundLayer pointerInput；课程块为 Button 消费自身点击）
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            handleEmptyTap(location, periodHeight: periodHeight, colWidth: colWidth)
        }
    }

    /// 点击无课区域 → (星期, 节次) 定位，打开新建编辑器预填。
    private func handleEmptyTap(_ location: CGPoint, periodHeight: CGFloat, colWidth: CGFloat) {
        guard colWidth > 0, periodHeight > 0, !sortedVisibleDays.isEmpty, !config.periods.isEmpty else { return }
        let gridHeight = periodHeight * CGFloat(config.periods.count)
        guard location.x >= Self.timeLabelWidth, location.y >= 0, location.y <= gridHeight else { return }
        let dayIndex = min(
            max(Int((location.x - Self.timeLabelWidth) / colWidth), 0),
            sortedVisibleDays.count - 1
        )
        let periodIndex = min(max(Int(location.y / periodHeight), 0), config.periods.count - 1)
        onEmptySlotClick(sortedVisibleDays[dayIndex], config.periods[periodIndex].index)
    }
}
