import Foundation
import GRDB

/// 课表元数据 + 课程 DAO。SQL 对照 Android `TableDao`/`CourseDao`。
///
/// **REPLACE 级联陷阱**：SQLite `INSERT OR REPLACE` = DELETE + INSERT，父行被替换会触发
/// `ON DELETE CASCADE` 清空子行。Android `insertTable`/`insertCourse` 用 `@Insert(REPLACE)`
/// 存在此隐患；iOS 端写入一律 `upsert()`（ON CONFLICT DO UPDATE，不删行），并用单测锁定
/// 「更新课表不清课程」。
struct TimetableDao: Sendable {
    let db: any DatabaseWriter

    /* ================= 课表元数据 ================= */

    func allTables() async throws -> [TableMetadataRecord] {
        try await db.read { db in
            try TableMetadataRecord.fetchAll(db, sql: "SELECT * FROM table_metadata ORDER BY id DESC")
        }
    }

    func tableById(id: Int64) async throws -> TableMetadataRecord? {
        try await db.read { db in
            try TableMetadataRecord.fetchOne(
                db, sql: "SELECT * FROM table_metadata WHERE id = ? LIMIT 1", arguments: [id]
            )
        }
    }

    func currentTable() async throws -> TableMetadataRecord? {
        try await db.read { db in
            try TableMetadataRecord.fetchOne(
                db, sql: "SELECT * FROM table_metadata WHERE isCurrent = 1 LIMIT 1"
            )
        }
    }

    /// 插入新课表（id 冲突则更新）。返回行 id。
    @discardableResult
    func insertTable(_ table: TableMetadataRecord) async throws -> Int64 {
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

    func updateTable(_ table: TableMetadataRecord) async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "UPDATE table_metadata SET tableName = ?, semesterConfig = ?, isCurrent = ? WHERE id = ?",
                arguments: [table.tableName, table.semesterConfig, table.isCurrent, table.id]
            )
        }
    }

    /// 切换当前活跃课表（原子事务：先全部清零再置位）。
    func setCurrentTable(tableId: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "UPDATE table_metadata SET isCurrent = 0")
            try db.execute(sql: "UPDATE table_metadata SET isCurrent = 1 WHERE id = ?", arguments: [tableId])
        }
    }

    func deleteTableById(tableId: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM table_metadata WHERE id = ?", arguments: [tableId])
        }
    }

    /// 自动清理：删除所有没有课程关联的空课表。
    func deleteEmptyTables() async throws {
        _ = try await db.write { db in
            try db.execute(
                sql: "DELETE FROM table_metadata WHERE id NOT IN (SELECT DISTINCT tableId FROM courses)"
            )
        }
    }

    /* ================= 课程 ================= */

    func courses(tableId: Int64) async throws -> [CourseRecord] {
        try await db.read { db in
            try CourseRecord.fetchAll(
                db, sql: "SELECT * FROM courses WHERE tableId = ?", arguments: [tableId]
            )
        }
    }

    func courses(tableId: Int64, dayOfWeek: Int) async throws -> [CourseRecord] {
        try await db.read { db in
            try CourseRecord.fetchAll(
                db,
                sql: "SELECT * FROM courses WHERE tableId = ? AND dayOfWeek = ? ORDER BY startPeriod ASC",
                arguments: [tableId, dayOfWeek]
            )
        }
    }

    /// 插入/更新课程（ON CONFLICT DO UPDATE，不用 REPLACE）。
    func upsertCourse(_ course: CourseRecord) async throws {
        _ = try await db.write { db in
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

    func upsertCourses(_ courses: [CourseRecord]) async throws {
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

    func deleteCourseById(courseId: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM courses WHERE id = ?", arguments: [courseId])
        }
    }

    func deleteCoursesByTableId(tableId: Int64) async throws {
        _ = try await db.write { db in
            try db.execute(sql: "DELETE FROM courses WHERE tableId = ?", arguments: [tableId])
        }
    }
}
