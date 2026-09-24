import Foundation
import GRDB
import WidgetKit
import OpenJWCCore

/// 小组件快照导出（design D-7/D-8）：当前表 + 节次 + 课程 → 快照 JSON 原子写
/// App Group 容器 → `WidgetCenter.reloadTimelines`。单写（主 app）多读（widget）。
/// 直接查 DB（与 TimetableStore 观察同源），不依赖观察器首推时序；
/// 无当前表时写空快照（widget 空态），避免删表后残留旧课表。
@MainActor
enum WidgetSnapshotWriter {
    static func export(db: any DatabaseWriter) async {
        let dao = TimetableDao(db: db)
        let table = try? await dao.currentTable()
        let courses: [CourseRecord]
        if let table {
            courses = (try? await dao.courses(tableId: table.id ?? 0)) ?? []
        } else {
            courses = []
        }
        let snapshot = table.map { WidgetSnapshot(table: $0, courses: courses) }
            ?? WidgetSnapshot(
                tableId: 0, tableName: "", startDate: "", totalWeeks: 0,
                periods: [], courses: []
            )

        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSharedKeys.appGroupId
        ) else { return }
        _ = snapshot.write(to: WidgetSnapshot.snapshotURL(containerURL: container))
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedKeys.widgetKind)
    }
}
