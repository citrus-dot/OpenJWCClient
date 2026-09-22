import SwiftUI
import OpenJWCCore

/// 学期配置编辑器（tasks 6.3 + 导入预览 7.2）：三模式复用同一表单。
/// - edit：编辑当前表 → updateTable（观察自动重算当前周）
/// - create：新建空白课表 → createTable（落库即切换）
/// - importPreview：导入预览确认 → confirmImport 事务（显示在用最大节次）
struct TableConfigSheet: View {
    enum Mode {
        case edit(TableMetadataRecord)
        case create
        case importPreview(TimetableJson.ParseResult)
    }

    let mode: Mode
    let coursesInUse: [CourseRecord]

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// 节次行（start/end 用当天 Date 承载 HH:mm 语义）。
    struct PeriodRow: Identifiable, Equatable {
        let id: UUID
        var index: Int
        var start: Date
        var end: Date
    }

    @State private var tableName = ""
    @State private var startDate = Date()
    @State private var weeks = 16.0
    @State private var showWeekend = true
    @State private var rows: [PeriodRow] = []
    @State private var initialized = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("课表名", text: $tableName)
                } footer: {
                    if tableName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("课表名不能为空").foregroundStyle(.red)
                    }
                }

                Section("学期") {
                    DatePicker("开学日期", selection: $startDate, displayedComponents: .date)
                        .onChange(of: startDate) { _, newValue in
                            startDate = Self.normalizeMonday(newValue)
                        }
                    VStack(alignment: .leading) {
                        Text("总周数：\(Int(weeks))")
                            .font(.callout)
                        Slider(value: $weeks, in: 1...30, step: 1)
                    }
                    Toggle("显示周末", isOn: $showWeekend)
                }

                Section {
                    ForEach($rows) { $row in
                        periodRow($row)
                    }
                    .onDelete { indexSet in
                        guard rows.count > indexSet.count else { return } // 至少保留 1 条
                        rows.remove(atOffsets: indexSet)
                        reindex()
                    }
                    Button {
                        addPeriod()
                    } label: {
                        Label("添加一节", systemImage: "plus.circle")
                    }
                } header: {
                    Text("节次时间")
                } footer: {
                    Text(footerText)
                }

                if case .importPreview(let result) = mode {
                    Section("导入预览") {
                        LabeledContent("课程数", value: "\(result.courses.count)")
                        LabeledContent("最晚用到", value: "第 \(maxPeriodInUse) 节")
                    }
                }
            }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(confirmTitle) { save() }
                        .disabled(!canConfirm)
                }
            }
            .onAppear { initializeIfNeeded() }
        }
    }

    // MARK: - 行视图

    @ViewBuilder
    private func periodRow(_ row: Binding<PeriodRow>) -> some View {
        HStack(spacing: 6) {
            Text("第 \(row.wrappedValue.index) 节")
                .font(.callout.monospacedDigit())
                .frame(width: 48, alignment: .leading)
            DatePicker("", selection: row.start, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
            Text("–").foregroundStyle(.secondary)
            DatePicker("", selection: row.end, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
            Spacer(minLength: 0)
        }
        .foregroundStyle(rowInvalid(row.wrappedValue) ? Color.red : Color.primary)
    }

    // MARK: - 校验与派生

    private var navigationTitleText: String {
        switch mode {
        case .edit: return "学期配置"
        case .create: return "新建课表"
        case .importPreview: return "确认导入"
        }
    }

    private var confirmTitle: String {
        if case .importPreview = mode { return "导入" }
        return "保存"
    }

    /// 在用最大节次（节数低于此值 → 警告但不阻断）。
    private var maxPeriodInUse: Int {
        coursesInUse.map { $0.startPeriod + $0.duration - 1 }.max() ?? 0
    }

    private var periodsBelowUse: Bool {
        !rows.isEmpty && maxPeriodInUse > 0 && rows.count < maxPeriodInUse
    }

    /// 单行止 > 起；相邻行不重叠（下一节起 > 上一节止）。
    private func rowInvalid(_ row: PeriodRow) -> Bool {
        Self.minutes(row.end) <= Self.minutes(row.start)
    }

    private var timeValid: Bool {
        guard !rows.isEmpty else { return false }
        for (i, row) in rows.enumerated() {
            if rowInvalid(row) { return false }
            if i > 0, Self.minutes(row.start) <= Self.minutes(rows[i - 1].end) {
                return false
            }
        }
        return true
    }

    private var canConfirm: Bool {
        !tableName.trimmingCharacters(in: .whitespaces).isEmpty && timeValid
    }

    private var footerText: String {
        var parts: [String] = []
        if !timeValid {
            parts.append("存在无效时间：止须晚于起，且节次间不得重叠。")
        }
        if periodsBelowUse {
            parts.append("警告：节数（\(rows.count)）低于课程在用的最大节次（第 \(maxPeriodInUse) 节），相关课程将无法显示。")
        }
        return parts.isEmpty
            ? "增：末节结束 +10 分钟起 45 分钟；删：左滑行。"
            : parts.joined(separator: "\n")
    }

    // MARK: - 初始化与保存

    private func initializeIfNeeded() {
        guard !initialized else { return }
        initialized = true
        switch mode {
        case .edit(let table):
            tableName = table.tableName
            startDate = Self.dateFromString(table.semesterConfig.startDate) ?? Self.normalizeMonday(Date())
            weeks = Double(max(min(table.semesterConfig.weeks, 30), 1))
            showWeekend = !table.semesterConfig.visibleDays.isDisjoint(with: [6, 7])
            rows = table.semesterConfig.periods.map {
                PeriodRow(id: UUID(), index: $0.index,
                          start: Self.timeFromString($0.start), end: Self.timeFromString($0.end))
            }
        case .create:
            let table = TimetableJson.defaultTable()
            tableName = table.tableName
            startDate = Self.dateFromString(table.semesterConfig.startDate) ?? Self.normalizeMonday(Date())
            weeks = 16
            showWeekend = true
            rows = table.semesterConfig.periods.map {
                PeriodRow(id: UUID(), index: $0.index,
                          start: Self.timeFromString($0.start), end: Self.timeFromString($0.end))
            }
        case .importPreview(let result):
            let table = result.metadata
            tableName = table.tableName
            startDate = Self.dateFromString(table.semesterConfig.startDate) ?? Self.normalizeMonday(Date())
            weeks = Double(max(min(table.semesterConfig.weeks, 30), 1))
            showWeekend = !table.semesterConfig.visibleDays.isDisjoint(with: [6, 7])
            rows = table.semesterConfig.periods.map {
                PeriodRow(id: UUID(), index: $0.index,
                          start: Self.timeFromString($0.start), end: Self.timeFromString($0.end))
            }
        }
    }

    private func addPeriod() {
        guard let last = rows.last else {
            let start = Self.timeFromString("08:00")
            rows.append(PeriodRow(id: UUID(), index: 1, start: start,
                                  end: Calendar.current.date(byAdding: .minute, value: 45, to: start) ?? start))
            return
        }
        let start = Calendar.current.date(byAdding: .minute, value: 10, to: last.end) ?? last.end
        let end = Calendar.current.date(byAdding: .minute, value: 45, to: start) ?? start
        rows.append(PeriodRow(id: UUID(), index: rows.count + 1, start: start, end: end))
    }

    private func reindex() {
        for i in rows.indices { rows[i].index = i + 1 }
    }

    private func buildConfig() -> SemesterConfig {
        SemesterConfig(
            startDate: Self.stringFromDate(startDate),
            weeks: Int(weeks),
            visibleDays: showWeekend ? [1, 2, 3, 4, 5, 6, 7] : [1, 2, 3, 4, 5],
            periods: rows.enumerated().map { i, row in
                SemesterConfig.Period(index: i + 1, start: Self.stringFromTime(row.start), end: Self.stringFromTime(row.end))
            }
        )
    }

    private func save() {
        let trimmedName = tableName.trimmingCharacters(in: .whitespaces)
        let config = buildConfig()
        let service = TimetableService(db: environment.db)
        Task {
            do {
                switch mode {
                case .edit(let table):
                    var updated = table
                    updated.tableName = trimmedName
                    updated.semesterConfig = config
                    try await service.updateTable(updated)
                case .create:
                    _ = try await service.createTable(TableMetadataRecord(
                        tableName: trimmedName, semesterConfig: config, isCurrent: true
                    ))
                case .importPreview(let result):
                    _ = try await service.confirmImport(
                        metadata: TableMetadataRecord(tableName: trimmedName, semesterConfig: config, isCurrent: true),
                        courses: result.courses
                    )
                }
                dismiss()
            } catch {
                NSLog("TableConfigSheet 保存失败: \(error)")
            }
        }
    }

    // MARK: - 时间/日期工具（HH:mm 与 Date 互转，仅取本地时刻语义）

    static func minutes(_ date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    static func timeFromString(_ hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else {
            var c = DateComponents(); c.hour = 8; c.minute = 0
            return Calendar.current.date(from: c) ?? Date()
        }
        var c = DateComponents(); c.hour = h; c.minute = m
        return Calendar.current.date(from: c) ?? Date()
    }

    static func stringFromTime(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    static func dateFromString(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar.current.date(from: c)
    }

    static func stringFromDate(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
    }

    /// 归一到所在周的周一（firstWeekday = 2）。
    static func normalizeMonday(_ date: Date) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }
}
