import Foundation
import GRDB

/// 课表编排服务（对齐 Android CourseRepository + TimetableViewModel 的写路径）：
/// 表 CRUD（创建即切换 / 删当前表自动切剩余首表）、课程增删改、导入落库事务。
/// 当前周不在此持久化——UI 层（TimetableStore）观察快照后按 `GrdbTimetableSource`
/// 的语义重算（周一为首 / 越界回 1 / 学期内 clamp）。
public final class TimetableService: Sendable {
    private let dao: TimetableDao

    public init(db: any DatabaseWriter) {
        self.dao = TimetableDao(db: db)
    }

    // MARK: - 表管理

    /// 创建课表：落库（isCurrent 置位）→ 原子切换为当前表。返回新表 id。
    @discardableResult
    public func createTable(_ table: TableMetadataRecord) async throws -> Int64 {
        var newTable = table
        newTable.isCurrent = true
        let id = try await dao.insertTable(newTable)
        try await dao.setCurrentTable(tableId: id)
        return id
    }

    /// 更新课表（名称/配置）。调用方保证 weeks 收缩时 UI 侧当前周 clamp 重算。
    public func updateTable(_ table: TableMetadataRecord) async throws {
        try await dao.updateTable(table)
    }

    /// 删除课表（级联删课程，外键 ON DELETE CASCADE）。
    /// 删除的是当前表时自动切换到剩余首表（无剩余返回 nil，UI 回空态）。
    @discardableResult
    public func deleteTable(tableId: Int64) async throws -> Int64? {
        let wasCurrent = try await dao.tableById(id: tableId)?.isCurrent ?? false
        try await dao.deleteTableById(tableId: tableId)
        guard wasCurrent else {
            return try await dao.currentTable()?.id
        }
        // 切换到剩余首表（allTables 按 id DESC；首表 = 最新一张）
        let remaining = try await dao.allTables()
        if let first = remaining.first {
            try await dao.setCurrentTable(tableId: first.id ?? 0)
            return first.id
        }
        return nil
    }

    /// 切换当前课表。
    public func switchTable(tableId: Int64) async throws {
        try await dao.setCurrentTable(tableId: tableId)
    }

    // MARK: - 课程

    /// 保存课程（id 为 nil 插入并返回行 id；有 id 更新）。
    @discardableResult
    public func saveCourse(_ course: CourseRecord) async throws -> Int64? {
        if course.id == nil {
            return try await dao.insertCourse(course)
        }
        try await dao.upsertCourse(course)
        return course.id
    }

    /// 删除课程。
    public func removeCourse(courseId: Int64) async throws {
        try await dao.deleteCourseById(courseId: courseId)
    }

    // MARK: - 导入（事务）

    /// 导入确认：单事务落库（存表 → 重映射 tableId → 批量插课程 → 切当前表）。
    /// 返回新表 id；当前周由 UI 重算为 1（新表 startDate 为默认值时自然回 1）。
    @discardableResult
    public func confirmImport(
        metadata: TableMetadataRecord, courses: [CourseRecord]
    ) async throws -> Int64 {
        try await dao.confirmImport(metadata: metadata, courses: courses)
    }
}
