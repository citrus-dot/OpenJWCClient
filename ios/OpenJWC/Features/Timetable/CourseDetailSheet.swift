import SwiftUI
import OpenJWCCore

/// 课程详情 sheet（tasks 5.1/5.2）：课程名为标题；非本周徽标；
/// 地点/教师（空值占位）、周次文案、星期与节次段；备注独立分组；编辑/删除（确认）。
struct CourseDetailSheet: View {
    let course: CourseRecord
    let currentWeek: Int
    let totalWeeks: Int
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var isCurrentWeek: Bool {
        course.weekRule.value.contains(currentWeek)
    }

    var body: some View {
        NavigationStack {
            List {
                if !isCurrentWeek {
                    Section {
                        Label("该课程不在本周", systemImage: "calendar.badge.exclamationmark")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    row("地点", course.location.isEmpty ? "未填写" : course.location)
                    row("教师", course.teacher.isEmpty ? "未填写" : course.teacher)
                    row("星期", Self.dayNames[course.dayOfWeek - 1])
                    row("节次", "第 \(course.startPeriod)–\(course.startPeriod + course.duration - 1) 节")
                    row("周次", weekText)
                }

                if !course.note.isEmpty {
                    Section("备注") {
                        Text(course.note)
                            .font(.callout)
                    }
                }

                Section {
                    Button {
                        dismiss()
                        onEdit()
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("删除课程", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(course.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("删除课程", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除「\(course.name)」", role: .destructive) {
                    dismiss()
                    onDelete()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("该课程将从课表中移除。")
            }
        }
        .presentationDetents([.medium])
    }

    private var weekText: String {
        let text = TimetableLayout.formatWeekRule(course.weekRule.value, totalWeeks: totalWeeks)
        return text.isEmpty ? "未设置" : text
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    static let dayNames = TimetableHeaderRow.dayNames
}
