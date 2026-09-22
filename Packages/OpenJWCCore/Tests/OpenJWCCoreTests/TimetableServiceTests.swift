import Foundation
import Testing
import GRDB
@testable import OpenJWCCore

/// TimetableService 测试（tasks 3.5）：建表即切换 / 删表切换链 / 导入重映射 / upsert 不清课程。
@Suite("TimetableService 编排")
struct TimetableServiceTests {

    private func makeTempDB() throws -> DatabaseProvider {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openjwc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DatabaseProvider(databasePath: dir.appendingPathComponent("test.sqlite").path)
    }

    private func table(_ name: String, isCurrent: Bool = false) -> TableMetadataRecord {
        TableMetadataRecord(
            tableName: name,
            semesterConfig: TimetableJson.defaultSemesterConfig(),
            isCurrent: isCurrent
        )
    }

    private func course(tableId: Int64, name: String = "高数", day: Int = 1) -> CourseRecord {
        CourseRecord(
            id: nil, tableId: tableId, name: name, teacher: "", location: "",
            dayOfWeek: day, startPeriod: 1, duration: 2,
            color: TimetableJson.deterministicColor(for: name),
            weekRule: JSONIntSet(Set(1...16)), note: ""
        )
    }

    @Test("建表即切换：isCurrent 唯一真源")
    func createTableSwitches() async throws {
        let db = try makeTempDB()
        let dao = TimetableDao(db: db.dbWriter)
        let service = TimetableService(db: db.dbWriter)

        let id1 = try await service.createTable(table("表A"))
        try await dao.upsertCourse(course(tableId: id1))
        let id2 = try await service.createTable(table("表B"))

        let current = try #require(try await dao.currentTable())
        #expect(current.id == id2)
        #expect(try await dao.allTables().filter(\.isCurrent).count == 1)
        // 旧表课程仍在（级联保护：切换不删数据）
        #expect(try await dao.courses(tableId: id1).count == 1)
    }

    @Test("删除当前表：自动切换剩余首表；删非当前表不动当前")
    func deleteTableSwitchChain() async throws {
        let db = try makeTempDB()
        let service = TimetableService(db: db.dbWriter)
        let dao = TimetableDao(db: db.dbWriter)

        let id1 = try await service.createTable(table("表1"))
        try await dao.upsertCourse(course(tableId: id1))
        let id2 = try await service.createTable(table("表2"))

        // 删非当前表（表1）→ 当前仍为表2
        try await service.deleteTable(tableId: id1)
        #expect(try await dao.currentTable()?.id == id2)

        // 删当前表（表2）→ 无剩余表 → nil（UI 回空态）
        let remaining = try await service.deleteTable(tableId: id2)
        #expect(remaining == nil)
        #expect(try await dao.allTables().isEmpty)
        #expect(try await dao.courses(tableId: id2).isEmpty) // 级联删除

        // 三表场景：删当前 → 切剩余首表（allTables 按 id DESC，首表 = 最新建的）
        _ = try await service.createTable(table("A"))
        let b = try await service.createTable(table("B"))
        let c = try await service.createTable(table("C")) // 当前
        let switched = try await service.deleteTable(tableId: c)
        #expect(switched == b) // 剩余中 id 最大（最新建）
        #expect(try await dao.currentTable()?.id == b)
    }

    @Test("导入事务：tableId 重映射 + 切当前表 + 周=1 语义（默认 startDate 早于今天）")
    func confirmImportTransaction() async throws {
        let db = try makeTempDB()
        let service = TimetableService(db: db.dbWriter)

        let parsed = try TimetableJson.parseExternal(json: """
        {"termName":"外部课表","rows":[{"name":"高数","dayOfWeek":2,"startPeriod":3,"endPeriod":4,"weeks":[1,2,3]}]}
        """)
        let newId = try await service.confirmImport(
            metadata: parsed.metadata, courses: parsed.courses
        )

        let dao = TimetableDao(db: db.dbWriter)
        let current = try #require(try await dao.currentTable())
        #expect(current.id == newId)
        #expect(current.tableName.hasPrefix("外部课表 ("))
        let imported = try await dao.courses(tableId: newId)
        #expect(imported.count == 1)
        #expect(imported[0].tableId == newId) // 重映射
        #expect(imported[0].name == "高数")

        // 默认 startDate = 当年 3 月 2 日：当年 9 月导入 → 已出学期 → clamp 至 weeks（非 1）
        // 1–4 月导入 → 学期内或未开始。这里只验证「可算出有效周或 nil→UI 回退」，不硬编码月份
        let week = GrdbTimetableSource.currentWeek(
            startDate: current.semesterConfig.startDate,
            weeks: current.semesterConfig.weeks,
            today: Date(), timeZone: .current
        )
        #expect(week == nil || (1...current.semesterConfig.weeks).contains(week!))
    }

    @Test("既有锁定复跑：更新课表不清课程（upsert 语义）+ 课程增删改")
    func upsertDoesNotClearCourses() async throws {
        let db = try makeTempDB()
        let dao = TimetableDao(db: db.dbWriter)
        let service = TimetableService(db: db.dbWriter)

        let id = try await service.createTable(table("锁定表"))
        let courseId = try #require(try await service.saveCourse(course(tableId: id)))

        // 更新课表（改名/改配置）→ 课程不丢
        var updated = try #require(try await dao.tableById(id: id))
        updated.tableName = "改名后"
        updated.semesterConfig.weeks = 18
        try await service.updateTable(updated)
        #expect(try await dao.courses(tableId: id).count == 1)

        // 更新课程
        var c = try #require(try await dao.courses(tableId: id).first)
        c.location = "新教室"
        try await service.saveCourse(c)
        #expect(try await dao.courses(tableId: id).first?.location == "新教室")

        // 删除课程
        try await service.removeCourse(courseId: courseId)
        #expect(try await dao.courses(tableId: id).isEmpty)
    }

    @Test("switchTable：切换与快照一致性")
    func switchTable() async throws {
        let db = try makeTempDB()
        let service = TimetableService(db: db.dbWriter)
        let dao = TimetableDao(db: db.dbWriter)
        let idA = try await service.createTable(table("A"))
        let idB = try await service.createTable(table("B"))

        try await service.switchTable(tableId: idA)
        #expect(try await dao.currentTable()?.id == idA)
        try await service.switchTable(tableId: idB)
        #expect(try await dao.currentTable()?.id == idB)
    }
}
