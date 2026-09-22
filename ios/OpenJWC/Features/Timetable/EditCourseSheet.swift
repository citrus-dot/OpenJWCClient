import SwiftUI
import OpenJWCCore

/// 课程编辑器（tasks 5.3/5.4）：新建（可带天/节预填）与编辑共用。
/// 名称必填；名称变更自动确定性重配色（手动选色后锁定）；
/// 与现有课程冲突时实时提示并禁用保存。
struct EditCourseSheet: View {
    let table: TableMetadataRecord
    let config: SemesterConfig
    let courses: [CourseRecord]
    let context: EditCourseContext

    enum WeekMode: Hashable {
        case every, odd, even, custom
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var teacher = ""
    @State private var location = ""
    @State private var note = ""
    @State private var day = 1
    @State private var startPeriod = 1
    @State private var endPeriod = 1
    @State private var weekMode: WeekMode = .every
    @State private var customWeeks: Set<Int> = []
    @State private var colorIndex = 0
    @State private var colorLocked = false
    @State private var initialized = false

    private var periods: [SemesterConfig.Period] { config.periods }
    private var maxPeriodIndex: Int { max(periods.count, 1) }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("课程名（必填）", text: $name)
                        .onChange(of: name) { _, newValue in
                            if !colorLocked { colorIndex = TimetableJson.colorIndex(for: newValue) }
                        }
                    TextField("教师", text: $teacher)
                    TextField("地点", text: $location)
                }

                Section("时间") {
                    Picker("星期", selection: $day) {
                        ForEach(1...7, id: \.self) { d in
                            Text(Self.dayNames[d - 1]).tag(d)
                        }
                    }
                    Picker("起始节", selection: $startPeriod) {
                        ForEach(1...maxPeriodIndex, id: \.self) { p in
                            Text("第 \(p) 节").tag(p)
                        }
                    }
                    .onChange(of: startPeriod) { _, newValue in
                        endPeriod = max(endPeriod, newValue)
                    }
                    Picker("结束节", selection: $endPeriod) {
                        ForEach(startPeriod...maxPeriodIndex, id: \.self) { p in
                            Text("第 \(p) 节").tag(p)
                        }
                    }
                }

                Section("周次规则") {
                    Picker("规则", selection: $weekMode) {
                        Text("每周").tag(WeekMode.every)
                        Text("单周").tag(WeekMode.odd)
                        Text("双周").tag(WeekMode.even)
                        Text("自定义").tag(WeekMode.custom)
                    }
                    .pickerStyle(.segmented)
                    if weekMode == .custom {
                        customWeekGrid
                    }
                }

                Section("颜色") {
                    colorPalette
                }

                Section("备注") {
                    TextField("备注", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let conflictText {
                    Section {
                        Label(conflictText, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "添加课程" : "编辑课程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear { initializeIfNeeded() }
        }
    }

    // MARK: - 自定义周次网格

    private var customWeekGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
            ForEach(1...max(config.weeks, 1), id: \.self) { week in
                let selected = customWeeks.contains(week)
                Button {
                    if selected { customWeeks.remove(week) } else { customWeeks.insert(week) }
                } label: {
                    Text("\(week)")
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 16 色板

    private var colorPalette: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
            ForEach(Array(TimetableJson.courseBackgroundColors.enumerated()), id: \.offset) { index, argb in
                Button {
                    colorIndex = index
                    colorLocked = true
                } label: {
                    Circle()
                        .fill(Color(argb: argb))
                        .frame(height: 28)
                        .overlay {
                            if index == colorIndex {
                                Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-3)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 状态派生

    private var isNew: Bool {
        if case .new = context { return true }
        return false
    }

    private var editingId: Int64? {
        if case .edit(let course) = context { return course.id }
        return nil
    }

    private var weekSet: Set<Int> {
        let total = max(config.weeks, 1)
        switch weekMode {
        case .every: return Set(1...total)
        case .odd: return Set((1...total).filter { $0 % 2 == 1 })
        case .even: return Set((1...total).filter { $0 % 2 == 0 })
        case .custom: return customWeeks
        }
    }

    /// 冲突域：同表其余课程（candidate id 与自身排除由 isConflicting 处理）。
    private var conflicts: [CourseRecord] {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return [] }
        let candidate = CourseRecord(
            id: editingId, tableId: table.id ?? 0, name: trimmedName,
            teacher: "", location: "", dayOfWeek: day,
            startPeriod: startPeriod, duration: endPeriod - startPeriod + 1,
            color: 0, weekRule: JSONIntSet(weekSet), note: ""
        )
        return courses.filter { $0.id != editingId && TimetableLayout.isConflicting(candidate, $0) }
    }

    /// 1 门显示课名；2 门显示首末；≥3 门显示前二 + 剩余数。
    private var conflictText: String? {
        guard !conflicts.isEmpty else { return nil }
        let names = conflicts.map(\.name)
        switch names.count {
        case 1:
            return "与「\(names[0])」时间冲突"
        case 2:
            return "与「\(names[0])」「\(names[1])」时间冲突"
        default:
            return "与「\(names[0])」「\(names[1])」等 \(names.count) 门课程时间冲突"
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && conflicts.isEmpty
    }

    // MARK: - 初始化与保存

    private func initializeIfNeeded() {
        guard !initialized else { return }
        initialized = true
        switch context {
        case .new(let prefilledDay, let prefilledPeriod):
            day = min(max(prefilledDay, 1), 7)
            startPeriod = min(max(prefilledPeriod, 1), maxPeriodIndex)
            endPeriod = min(startPeriod + 1, maxPeriodIndex) // 默认连堂 2 节
            weekMode = .every
            colorIndex = TimetableJson.colorIndex(for: "")
        case .edit(let course):
            name = course.name
            teacher = course.teacher
            location = course.location
            note = course.note
            day = course.dayOfWeek
            startPeriod = course.startPeriod
            endPeriod = course.startPeriod + course.duration - 1
            let total = max(config.weeks, 1)
            let rule = course.weekRule.value
            if rule == Set(1...total) {
                weekMode = .every
            } else if rule == Set((1...total).filter { $0 % 2 == 1 }) {
                weekMode = .odd
            } else if rule == Set((1...total).filter { $0 % 2 == 0 }) {
                weekMode = .even
            } else {
                weekMode = .custom
                customWeeks = rule
            }
            // 现存颜色若偏离名称确定性色，视为用户手动改过 → 锁定
            colorIndex = TimetableJson.courseBackgroundColors.firstIndex(of: course.color)
                ?? TimetableJson.colorIndex(for: course.name)
            colorLocked = course.color != TimetableJson.deterministicColor(for: course.name)
        }
    }

    private func save() {
        let record = CourseRecord(
            id: editingId, tableId: table.id ?? 0,
            name: name.trimmingCharacters(in: .whitespaces),
            teacher: teacher.trimmingCharacters(in: .whitespaces),
            location: location.trimmingCharacters(in: .whitespaces),
            dayOfWeek: day,
            startPeriod: startPeriod,
            duration: endPeriod - startPeriod + 1,
            color: TimetableJson.courseBackgroundColors[colorIndex],
            weekRule: JSONIntSet(weekSet),
            note: note.trimmingCharacters(in: .whitespaces)
        )
        let service = TimetableService(db: environment.db)
        Task {
            do {
                _ = try await service.saveCourse(record)
                dismiss()
            } catch {
                NSLog("EditCourseSheet 保存失败: \(error)")
            }
        }
    }

    static let dayNames = TimetableHeaderRow.dayNames
}
