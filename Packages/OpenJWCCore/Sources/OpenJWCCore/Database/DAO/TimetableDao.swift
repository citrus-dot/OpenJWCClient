import Foundation
import GRDB

/// 课表元数据 + 课程 DAO。SQL 对照 Android `TableDao`/`CourseDao`。
///
/// **REPLACE 级联陷阱**：SQLite `INSERT OR REPLACE` = DELETE + INSERT，父行被替换会触发
/// `ON DELETE CASCADE` 清空子行。Android `insertTable`/`insertCourse` 用 `@Insert(REPLACE)`
/// 存在此隐患；iOS 端写入一律 `upsert()`（ON CONFLICT DO UPDATE，不删行），并用单测锁定
/// 「更新课表不清课程」。
public struct TimetableDao: Sendable {
    let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    /* ================= ValueObservation 静态查询（同步 read 上下文） ================= */

    /// 全部课表（id 倒序；观察闭包用）。
    public static func allTablesSync(_ db: Database) throws -> [TableMetadataRecord] {
        try TableMetadataRecord.fetchAll(db, sql: "SELECT * FROM table_metadata ORDER BY id DESC")
    }

    /// 某表全部课程（观察闭包用）。
    public static func coursesSync(_ db: Database, tableId: Int64) throws -> [CourseRecord] {
        try CourseRecord.fetchAll(db, sql: "SELECT * FROM courses WHERE tableId = ?", arguments: [tableId])
    }

    /// 导入落库事务（对齐 Android confirmImport）：存表 → 重映射课程 tableId →
    /// 批量 upsert 课程 → 切换当前表。单事务保证中途失败不残留半截数据。
    public static func confirmImportSync(
        _ db: Database,
        metadata: TableMetadataRecord,
        courses: [CourseRecord]
    ) throws -> Int64 {
        try db.execute(sql: "UPDATE table_metadata SET isCurrent = 0")
        try db.execute(
            sql: "INSERT INTO table_metadata(tableName, semesterConfig, isCurrent) VALUES (?, ?, 1)",
            arguments: [metadata.tableName, metadata.semesterConfig]
        )
        let newTableId = db.lastInsertedRowID
        for course in courses {
            try db.execute(
                sql: """
                INSERT INTO courses(tableId, name, teacher, location, dayOfWeek, startPeriod,
                                    duration, color, weekRule, note) \
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    newTableId, course.name, course.teacher, course.location,
                    course.dayOfWeek, course.startPeriod, course.duration,
                    course.color, course.weekRule, course.note,
                ]
            )
        }
        return newTableId
    }

    /* ================= 课表元数据 ================= */

    public func allTables() async throws -> [TableMetadataRecord] {
        try await db.read { db in
            try TableMetadataRecord.fetchAll(db, sql: "SELECT * FROM table_metadata ORDER BY id DESC")
        }
    }

    public func tableById(id: Int64) async throws -> TableMetadataRecord? {
        try await db.read { db in
            try TableMetadataRecord.fetchOne(
                db, sql: "SELECT * FROM table_metadata WHERE id = ? LIMIT 1", arguments: [id]
            )
        }
    }

    public func currentTable() async throws -> TableMetadataRecord? {
        try await db.read { db in
            try TableMetadataRecord.fetchOne(
                db, sql: "SELECT * FROM table_metadata WHERE isCurrent = 1 LIMIT 1"
            )
        }
    }

    /// 插入新课表（id 冲突则更新）。返回行 id。
    @discardableResult
    public func insertTable(_ table: TableMetadataRecord) async throws -> Int64 {
        try await db.write { db in
            try db.execute(
                sql: """
                INSERT INTO table_metadata(tableName, semesterConfig, isCurrent) \
                VALUES (?, ?, ?) \
                ON CONFLICT(id) DO UPDATE SET \
                    tableName = excluded.tableName, \
                    semesterConfig = excluded.semesterConfig, \
                    isCurrent = excluded.isCurrent
                """,
                arguments: [table.tableName, table.semesterConfig, table.isCurrent]
            )
            return table.id ?? db.lastInsertedRowID
        }
    }

    public func updateTable(_ table: TableMetadataRecord) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE table_metadata SET tableName = ?, semesterConfig = ?, isCurrent = ? WHERE id = ?",
                arguments: [table.tableName, table.semesterConfig, table.isCurrent, table.id]
            )
        }
    }

    /// 切换当前活跃课表（原子事务：先全部清零再置位）。
    public func setCurrentTable(tableId: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "UPDATE table_metadata SET isCurrent = 0")
            try db.execute(sql: "UPDATE table_metadata SET isCurrent = 1 WHERE id = ?", arguments: [tableId])
        }
    }

    public func deleteTableById(tableId: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM table_metadata WHERE id = ?", arguments: [tableId])
        }
    }

    /// 自动清理：删除所有没有课程关联的空课表。
    public func deleteEmptyTables() async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "DELETE FROM table_metadata WHERE id NOT IN (SELECT DISTINCT tableId FROM courses)"
            )
        }
    }

    /* ================= 课程 ================= */

    public func courses(tableId: Int64) async throws -> [CourseRecord] {
        try await db.read { db in
            try CourseRecord.fetchAll(
                db, sql: "SELECT * FROM courses WHERE tableId = ?", arguments: [tableId]
            )
        }
    }

    public func courses(tableId: Int64, dayOfWeek: Int) async throws -> [CourseRecord] {
        try await db.read { db in
            try CourseRecord.fetchAll(
                db,
                sql: "SELECT * FROM courses WHERE tableId = ? AND dayOfWeek = ? ORDER BY startPeriod ASC",
                arguments: [tableId, dayOfWeek]
            )
        }
    }

    /// 插入新课程（INSERT，返回行 id）。
    @discardableResult
    public func insertCourse(_ course: CourseRecord) async throws -> Int64 {
        try await db.write { db in
            try db.execute(
                sql: """
                INSERT INTO courses(tableId, name, teacher, location, dayOfWeek, startPeriod,
                                    duration, color, weekRule, note) \
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    course.tableId, course.name, course.teacher, course.location,
                    course.dayOfWeek, course.startPeriod, course.duration,
                    course.color, course.weekRule, course.note,
                ]
            )
            return db.lastInsertedRowID
        }
    }

    /// 导入落库事务（对齐 Android confirmImport）：存表 → 重映射课程 tableId →
    /// 批量插课程 → 切当前表。单事务保证中途失败不残留半截数据。
    @discardableResult
    public func confirmImport(
        metadata: TableMetadataRecord,
        courses: [CourseRecord]
    ) async throws -> Int64 {
        try await db.write { db in
            try TimetableDao.confirmImportSync(db, metadata: metadata, courses: courses)
        }
    }

    /// 插入/更新课程（ON CONFLICT DO UPDATE，不用 REPLACE）。
    /// 显式携带 id：nil → SQLite 自动分配（INSERT 路径）；有值 → 冲突命中走 UPDATE。
    public func upsertCourse(_ course: CourseRecord) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: """
                INSERT INTO courses(id, tableId, name, teacher, location, dayOfWeek, startPeriod,
                                    duration, color, weekRule, note) \
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
                ON CONFLICT(id) DO UPDATE SET \
                    tableId = excluded.tableId, name = excluded.name, teacher = excluded.teacher, \
                    location = excluded.location, dayOfWeek = excluded.dayOfWeek, \
                    startPeriod = excluded.startPeriod, duration = excluded.duration, \
                    color = excluded.color, weekRule = excluded.weekRule, note = excluded.note
                """,
                arguments: [
                    course.id, course.tableId, course.name, course.teacher, course.location,
                    course.dayOfWeek, course.startPeriod, course.duration,
                    course.color, course.weekRule, course.note,
                ]
            )
        }
    }

    public func upsertCourses(_ courses: [CourseRecord]) async throws {
        _ = try await db.write { db in
            for course in courses {
                try db.execute(
                    sql: """
                    INSERT INTO courses(tableId, name, teacher, location, dayOfWeek, startPeriod,
                                        duration, color, weekRule, note) \
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
                    ON CONFLICT(id) DO UPDATE SET \
                        tableId = excluded.tableId, name = excluded.name, teacher = excluded.teacher, \
                        location = excluded.location, dayOfWeek = excluded.dayOfWeek, \
                        startPeriod = excluded.startPeriod, duration = excluded.duration, \
                        color = excluded.color, weekRule = excluded.weekRule, note = excluded.note
                    """,
                    arguments: [
                        course.tableId, course.name, course.teacher, course.location,
                        course.dayOfWeek, course.startPeriod, course.duration,
                        course.color, course.weekRule, course.note,
                    ]
                )
            }
        }
    }

    /// 移动课程位置（拖拽调课专用 UPDATE：WHERE id 精确命中，杜绝复制行）。
    /// 返回受影响行数（0 = 目标课程不存在）。
    @discardableResult
    public func updateCoursePosition(courseId: Int64, dayOfWeek: Int, startPeriod: Int) async throws -> Int {
        let day: Int = dayOfWeek
        let start: Int = startPeriod
        let id: Int64 = courseId
        return try await db.write { db in
            try db.execute(
                sql: "UPDATE courses SET dayOfWeek = ?, startPeriod = ? WHERE id = ?",
                arguments: [day, start, id]
            )
            return db.changesCount
        }
    }

    public func deleteCourseById(courseId: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM courses WHERE id = ?", arguments: [courseId])
        }
    }

    public func deleteCoursesByTableId(tableId: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM courses WHERE tableId = ?", arguments: [tableId])
        }
    }
}
