import Foundation
import Testing
@testable import OpenJWCCore

/// TimetableJson 测试（tasks 2.5）：稳定哈希 / 配色 / 解析族 / 导出族 / 回环。
@Suite("TimetableJson 解析与导出")
struct TimetableJsonTests {

    // MARK: - stableJavaHash（Java String.hashCode 直译，已知值对照）

    @Test("stableJavaHash：ASCII/中文/混合/空串 与 Java 计算值一致")
    func javaHashKnownValues() {
        #expect(TimetableJson.stableJavaHash("") == 0)
        #expect(TimetableJson.stableJavaHash("hello") == 99_162_322)
        #expect(TimetableJson.stableJavaHash("高数") == 1_254_808)
        #expect(TimetableJson.stableJavaHash("高等数学") == 1_212_073_767)
        #expect(TimetableJson.stableJavaHash("大学物理") == 703_343_132)
        #expect(TimetableJson.stableJavaHash("体育") == 662_463)
        #expect(TimetableJson.stableJavaHash("C++ 程序设计") == -1_767_065_180)
    }

    @Test("colorIndex：确定性 + 越界安全 + 与 Android 同名同色")
    func deterministicColor() {
        // 高数 hash=1254808 → &0x7FFFFFFF % 16 = 1254808 % 16 = 8
        #expect(TimetableJson.colorIndex(for: "高数") == 8)
        #expect(TimetableJson.deterministicColor(for: "高数")
            == TimetableJson.courseBackgroundColors[8])
        // 负 hash：C++ 程序设计 → &0x7FFFFFFF 后非负
        let idx = TimetableJson.colorIndex(for: "C++ 程序设计")
        #expect(idx >= 0 && idx < 16)
        // 同名同色
        #expect(TimetableJson.deterministicColor(for: "体育") == TimetableJson.deterministicColor(for: "体育"))
    }

    // MARK: - parseWeekRange

    @Test("周次文本解析：区间/单双/逗号/纯数字/空")
    func weekRange() {
        #expect(TimetableJson.parseWeekRange("") == [])
        #expect(TimetableJson.parseWeekRange("   ") == [])
        #expect(TimetableJson.parseWeekRange("1-16周") == Array(1...16))
        #expect(TimetableJson.parseWeekRange("1-16周(单)") == Array(stride(from: 1, through: 16, by: 2)))
        #expect(TimetableJson.parseWeekRange("2-16周(双)") == Array(stride(from: 2, through: 16, by: 2)))
        #expect(TimetableJson.parseWeekRange("2,4,6周") == [2, 4, 6])
        #expect(TimetableJson.parseWeekRange("1-8周,10,12") == Array(1...8) + [10, 12])
        #expect(TimetableJson.parseWeekRange("5") == [5])
    }

    // MARK: - parseExternal

    private func row(
        name: String?, day: Int = 1, start: Int = 1, end: Int = 2,
        weeks: Any = [1, 2], teacher: String? = nil, location: String? = nil,
        note: String? = nil
    ) -> [String: Any] {
        var obj: [String: Any] = [:]
        if let name { obj["name"] = name }
        obj["dayOfWeek"] = day
        obj["startPeriod"] = start
        obj["endPeriod"] = end
        obj["weeks"] = weeks
        if let teacher { obj["teacher"] = teacher }
        if let location { obj["location"] = location }
        if let note { obj["note"] = note }
        return obj
    }

    private func json(_ rows: [[String: Any]], termName: String = "我的课表") throws -> String {
        let wrapped: [String: Any] = ["termName": termName, "rows": rows]
        let data = try JSONSerialization.data(withJSONObject: wrapped)
        return String(data: data, encoding: .utf8)!
    }

    @Test("解析：正常行全字段 + 确定性配色 + 表名时间戳")
    func parseBasic() throws {
        let result = try TimetableJson.parseExternal(json: try json([
            row(name: "高数", day: 3, start: 3, end: 4, weeks: [1, 2, 3],
                teacher: "张三", location: "教一-101", note: "带教材")
        ]))
        #expect(result.courses.count == 1)
        let c = result.courses[0]
        #expect(c.name == "高数")
        #expect(c.dayOfWeek == 3)
        #expect(c.startPeriod == 3 && c.duration == 2)
        #expect(c.teacher == "张三" && c.location == "教一-101" && c.note == "带教材")
        #expect(c.weekRule.value == [1, 2, 3])
        #expect(c.color == TimetableJson.deterministicColor(for: "高数"))
        #expect(result.metadata.tableName.hasPrefix("我的课表 ("))
        #expect(result.metadata.isCurrent)
        #expect(result.metadata.semesterConfig.weeks == 16) // 推断下限
    }

    @Test("解析：weeks 三态（数字数组/字符串数组/单字符串/单数字）")
    func weeksVariants() throws {
        let r1 = try TimetableJson.parseExternal(json: try json([
            row(name: "A", weeks: [1, 3, 5]),
        ]))
        #expect(r1.courses[0].weekRule.value == [1, 3, 5])

        let r2 = try TimetableJson.parseExternal(json: try json([
            row(name: "B", weeks: ["1-8周", "10,12"]),
        ]))
        #expect(r2.courses[0].weekRule.value == Set(1...8).union([10, 12]))

        let r3 = try TimetableJson.parseExternal(json: try json([
            row(name: "C", weeks: "1-16周(单)"),
        ]))
        #expect(r3.courses[0].weekRule.value == Set(stride(from: 1, through: 16, by: 2)))

        let r4 = try TimetableJson.parseExternal(json: try json([
            row(name: "D", weeks: 7),
        ]))
        #expect(r4.courses[0].weekRule.value == [7])
    }

    @Test("解析：\"null\" 字符串清理 + 无效行丢弃")
    func nullCleaningAndRowDropping() throws {
        let result = try TimetableJson.parseExternal(json: try json([
            row(name: "有效课", teacher: "null", location: "null"),
            row(name: nil, weeks: [1]),          // 缺名丢弃
            row(name: "无周次", weeks: []),       // 无周次丢弃（end 默认 0 → weeks 空数组场景）
        ]))
        #expect(result.courses.count == 1)
        #expect(result.courses[0].teacher == "")
        #expect(result.courses[0].location == "")
    }

    @Test("解析：推断 weekends/最大周数/13 节自动扩展")
    func inference() throws {
        let result = try TimetableJson.parseExternal(json: try json([
            row(name: "周末课", day: 6, start: 14, end: 15, weeks: Array(1...20)),
        ]))
        #expect(result.metadata.semesterConfig.weeks == 20)
        #expect(result.metadata.semesterConfig.visibleDays == [1, 2, 3, 4, 5, 6, 7])
        // 15 节 > 13 → 自动扩展 14、15 节（21:30–22:15）
        #expect(result.metadata.semesterConfig.periods.count == 15)
        #expect(result.metadata.semesterConfig.periods[13] == SemesterConfig.Period(index: 14, start: "21:30", end: "22:15"))
        #expect(result.metadata.semesterConfig.periods[14] == SemesterConfig.Period(index: 15, start: "21:30", end: "22:15"))
        // 工作日课表 → 五天
        let weekday = try TimetableJson.parseExternal(json: try json([
            row(name: "工作日课", day: 5, weeks: [1]),
        ]))
        #expect(weekday.metadata.semesterConfig.visibleDays == [1, 2, 3, 4, 5])
    }

    @Test("解析失败：rows 缺失/空 rows 抛具体错误")
    func parseErrors() {
        #expect(throws: TimetableJson.ParseError.self) {
            try TimetableJson.parseExternal(json: #"{"termName":"x"}"#)
        }
        #expect(throws: TimetableJson.ParseError.self) {
            try TimetableJson.parseExternal(json: #"{"termName":"x","rows":[]}"#)
        }
        #expect(throws: TimetableJson.ParseError.self) {
            try TimetableJson.parseExternal(json: "不是 JSON")
        }
    }

    // MARK: - buildExport 与回环

    @Test("导出：规范化键 + 可选字段非空才写 + 空表 nil")
    func exportShape() throws {
        let table = TableMetadataRecord(tableName: "2026 秋", semesterConfig: .init(startDate: "", weeks: 16, visibleDays: [], periods: []), isCurrent: true)
        let course = CourseRecord(
            id: 1, tableId: 1, name: "高数", teacher: "", location: "A101",
            dayOfWeek: 2, startPeriod: 3, duration: 2, color: 0,
            weekRule: JSONIntSet([3, 1, 2]), note: ""
        )
        let exported = try #require(TimetableJson.buildExport(table: table, courses: [course]))

        // 可选字段：teacher/note 空不写；location 非空写
        #expect(exported.contains("\"teacher\"") == false)
        #expect(exported.contains("\"note\"") == false)
        #expect(exported.contains("\"location\": \"A101\""))
        #expect(exported.contains("\"termName\": \"2026 秋\""))
        #expect(exported.contains("\"weeks\": [1,2,3]"))
        #expect(exported.contains("\"endPeriod\": 4"))

        // 空表 → nil
        #expect(TimetableJson.buildExport(table: table, courses: []) == nil)
    }

    @Test("导出↔导入回环：课程/颜色/周次一致")
    func exportImportRoundtrip() throws {
        let table = TableMetadataRecord(tableName: "回环测试", semesterConfig: .init(startDate: "", weeks: 16, visibleDays: [], periods: []), isCurrent: true)
        let courses = [
            CourseRecord(id: 1, tableId: 1, name: "高等数学", teacher: "李四", location: "",
                         dayOfWeek: 1, startPeriod: 1, duration: 2, color: 0,
                         weekRule: JSONIntSet(Set(1...16)), note: ""),
            CourseRecord(id: 2, tableId: 1, name: "体育", teacher: "", location: "操场",
                         dayOfWeek: 5, startPeriod: 6, duration: 1, color: 0,
                         weekRule: JSONIntSet([2, 4, 6]), note: "带上球拍"),
        ]
        let exported = try #require(TimetableJson.buildExport(table: table, courses: courses))
        let reparsed = try TimetableJson.parseExternal(json: exported)

        #expect(reparsed.courses.count == 2)
        // 同名同色（确定性配色回环）
        for (orig, re) in zip(courses, reparsed.courses) {
            #expect(re.name == orig.name)
            #expect(re.dayOfWeek == orig.dayOfWeek)
            #expect(re.startPeriod == orig.startPeriod && re.duration == orig.duration)
            #expect(re.weekRule.value == orig.weekRule.value)
            #expect(re.teacher == orig.teacher && re.location == orig.location && re.note == orig.note)
            #expect(re.color == TimetableJson.deterministicColor(for: orig.name))
        }
    }
}
