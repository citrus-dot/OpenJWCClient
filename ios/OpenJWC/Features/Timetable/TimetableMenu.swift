import SwiftUI

/// 课表管理菜单（对齐 Android TimetableAction：切表/表配置/加课/导出/文件导入/建空表/删表；
/// AddShortCut 桌面快捷方式为平台特有能力，iOS 不提供）。
struct TimetableMenu: View {
    let onTableSelect: () -> Void
    let onTableConfig: () -> Void
    let onAddCourse: () -> Void
    let onExport: () -> Void
    let onImport: () -> Void
    let onCreateTable: () -> Void
    let onDeleteTable: () -> Void

    var body: some View {
        Menu {
            Button { onTableSelect() } label: {
                Label("切换课表", systemImage: "list.bullet.rectangle")
            }
            Button { onTableConfig() } label: {
                Label("学期配置", systemImage: "gearshape.2")
            }
            Button { onAddCourse() } label: {
                Label("添加课程", systemImage: "plus.circle")
            }
            Divider()
            Button { onExport() } label: {
                Label("导出 JSON", systemImage: "square.and.arrow.up")
            }
            Button { onImport() } label: {
                Label("导入 JSON 文件", systemImage: "square.and.arrow.down")
            }
            Divider()
            Button { onCreateTable() } label: {
                Label("新建空白课表", systemImage: "doc.badge.plus")
            }
            Button(role: .destructive) { onDeleteTable() } label: {
                Label("删除当前课表", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("课表管理")
    }
}
