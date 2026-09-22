import Foundation

// MARK: - 课表 JSON 导入解析与导出序列化（直译 Android TableParserUtils + CourseRepository.parseExternalJson + TimetableViewModel.buildExportJson）

public enum TimetableJson {

    // MARK: - 稳定哈希（D-7 关键移植）

    /// Java `String.hashCode` 直译：UTF-16 码元多项式 ×31，Int32 环绕运算。
    /// Swift `String.hashValue` 按进程随机播种，绝不可用于持久性配色。
    public static func stableJavaHash(_ s: String) -> Int32 {
        var hash: Int32 = 0
        for unit in s.utf16 {
            hash = (hash &* 31) &+ Int32(truncatingIfNeeded: unit)
        }
        return hash
    }

    /// 16 色板（对齐 Android Color.kt courseBackgroundColors，ARGB Int64）。
    public static let courseBackgroundColors: [Int64] = [
        0xFFC62828, 0xFFAD1457, 0xFF6A1B9A, 0xFF4527A0,
        0xFF283593, 0xFF1565C0, 0xFF0277BD, 0xFF00838F,
        0xFF00695C, 0xFF2E7D32, 0xFF558B2F, 0xFFFF8F00,
        0xFFEF6C00, 0xFFD84315, 0xFF4E342E, 0xFF37474F,
    ]

    /// 确定性配色索引：`(hash and 0x7FFFFFFF) % 16`（对齐 Android EditCourseViewModel；
    /// 与 TableParserUtils 的 abs 版在 Int32 域等价，iOS 统一取前者，避开 Int32.min 取 abs 陷阱）。
    public static func colorIndex(for name: String) -> Int {
        Int(stableJavaHash(name) & 0x7FFF_FFFF) % courseBackgroundColors.count
    }

    /// 确定性配色（同名同色，双端一致）。
    public static func deterministicColor(for name: String) -> Int64 {
        courseBackgroundColors[colorIndex(for: name)]
    }

    // MARK: - 默认学期配置（对齐 SemesterConfig.default()）

    /// 默认 13 节时间表；开学日期默认当年 3 月 2 日（Android 语义）。
    public static func defaultSemesterConfig(now: Date = Date()) -> SemesterConfig {
        let year = Calendar.current.component(.year, from: now)
        return SemesterConfig(
            startDate: String(format: "%d-03-02", year),
            weeks: 16,
            visibleDays: [1, 2, 3, 4, 5, 6, 7],
            periods: [
                SemesterConfig.Period(index: 1, start: "08:00", end: "08:45"),
                SemesterConfig.Period(index: 2, start: "08:50", end: "09:35"),
                SemesterConfig.Period(index: 3, start: "09:50", end: "10:35"),
                SemesterConfig.Period(index: 4, start: "10:40", end: "11:25"),
                SemesterConfig.Period(index: 5, start: "11:30", end: "12:15"),
                SemesterConfig.Period(index: 6, start: "14:00", end: "14:45"),
                SemesterConfig.Period(index: 7, start: "14:50", end: "15:35"),
                SemesterConfig.Period(index: 8, start: "15:50", end: "16:35"),
                SemesterConfig.Period(index: 9, start: "16:40", end: "17:25"),
                SemesterConfig.Period(index: 10, start: "17:30", end: "18:15"),
                SemesterConfig.Period(index: 11, start: "19:00", end: "19:45"),
                SemesterConfig.Period(index: 12, start: "19:50", end: "20:35"),
                SemesterConfig.Period(index: 13, start: "20:40", end: "21:25"),
            ]
        )
    }

    // MARK: - 周次解析（直译 parseWeekRange）

    /// 解析周次文本（如 "1-16周"、"1-10周(单)"、"2,4,6周"、"1-8"）。
    public static func parseWeekRange(_ weekText: String) -> [Int] {
        let trimmed = weekText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var allWeeks = Set<Int>()
        // 正则：匹配 开始周-结束周、周、(单/双)
        let pattern = "(\\d+)(?:-(\\d+))?周?(?:\\(([单双])\\))?"
        let regex = try? NSRegularExpression(pattern: pattern)
        for part in trimmed.components(separatedBy: ",") {
            let range = NSRange(part.startIndex..., in: part)
            guard let match = regex?.firstMatch(in: part, options: [], range: range) else { continue }
            let group = { (i: Int) -> String in
                guard i < match.numberOfRanges, let r = Range(match.range(at: i), in: part) else { return "" }
                return String(part[r])
            }
            guard let start = Int(group(1)) else { continue }
            let end = group(2).isEmpty ? start : (Int(group(2)) ?? start)
            let type = group(3)

            for w in start...end where w > 0 {
                let isMatch: Bool
                switch type {
                case "单": isMatch = w % 2 != 0
                case "双": isMatch = w % 2 == 0
                default: isMatch = true
                }
                if isMatch { allWeeks.insert(w) }
            }
        }
        return allWeeks.sorted()
    }

    // MARK: - 解析结果

    public struct ParseResult: Equatable, Sendable {
        public var metadata: TableMetadataRecord
        public var courses: [CourseRecord]
    }

    public enum ParseError: Error, LocalizedError {
        case missingRows
        case emptyRows

        public var errorDescription: String? {
            switch self {
            case .missingRows: return "解析错误：未找到课程数据(rows)"
            case .emptyRows: return "解析错误：课表内容为空"
            }
        }
    }

    // MARK: - 导入解析（直译 parseExternalJson + parseCoursesFromJsonArray）

    /// 解析外部 JSON（Android 抓取端已把教务字段规范化为 name/teacher/location/…）。
    /// 推断总周数（≥16）/是否含周末/最大节次（超 13 自动补节 21:30–22:15）；
    /// 表名追加 `(MM-dd HH:mm)` 时间戳；无效行（无 name / 无周次）丢弃。
    public static func parseExternal(
        json: String, now: Date = Date()
    ) throws -> ParseResult {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.missingRows
        }
        let termName = (root["termName"] as? String).flatMap(clean) ?? "导入课表"
        guard let rowsArray = root["rows"] as? [[String: Any]] else {
            throw ParseError.missingRows
        }
        if rowsArray.isEmpty { throw ParseError.emptyRows }

        struct RawRow {
            var name: String?
            var teacher: String
            var location: String
            var dayValue: Int
            var start: Int
            var end: Int
            var weeks: [Int]
            var note: String
        }

        let rows: [RawRow] = rowsArray.map { obj in
            RawRow(
                name: (obj["name"] as? String).flatMap(firstStringClean),
                teacher: (obj["teacher"] as? String).flatMap(firstStringClean) ?? "",
                location: (obj["location"] as? String).flatMap(firstStringClean) ?? "",
                dayValue: firstInt(obj, "dayOfWeek") ?? 1,
                start: firstInt(obj, "startPeriod") ?? 1,
                end: firstInt(obj, "endPeriod") ?? 0,
                weeks: extractWeeks(obj),
                note: (obj["note"] as? String).flatMap(firstStringClean) ?? ""
            )
        }

        // 从数据推断课表全局配置
        var inferredMaxWeek = 16
        var inferredHasWeekend = false
        var inferredMaxPeriod = 13
        for row in rows {
            if let maxWeek = row.weeks.max() {
                inferredMaxWeek = max(inferredMaxWeek, maxWeek)
            }
            if row.dayValue >= 6 {
                inferredHasWeekend = true
            }
            if row.end > inferredMaxPeriod {
                inferredMaxPeriod = row.end
            }
        }

        var courses: [CourseRecord] = []
        for row in rows {
            guard !row.weeks.isEmpty else { continue }   // 无有效周次丢弃
            guard let courseName = row.name else { continue } // 缺名丢弃
            let start = max(row.start, 1)
            let end = row.end >= start ? row.end : start
            courses.append(CourseRecord(
                id: nil, tableId: 0,
                name: courseName,
                teacher: row.teacher,
                location: row.location,
                dayOfWeek: (1...7).contains(row.dayValue) ? row.dayValue : 1,
                startPeriod: start,
                duration: end - start + 1,
                color: deterministicColor(for: courseName),
                weekRule: JSONIntSet(Set(row.weeks)),
                note: row.note
            ))
        }

        // 自动识别可见天数：含周末课程则全周，否则工作日五天
        let visibleDays: Set<Int> = inferredHasWeekend ? [1, 2, 3, 4, 5, 6, 7] : [1, 2, 3, 4, 5]

        // 自动补全节次：超默认 13 节则按 21:30–22:15 模板扩展
        var defaultConfig = defaultSemesterConfig(now: now)
        if inferredMaxPeriod > defaultConfig.periods.count {
            for i in (defaultConfig.periods.count + 1)...inferredMaxPeriod {
                defaultConfig.periods.append(SemesterConfig.Period(index: i, start: "21:30", end: "22:15"))
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timeStamp = formatter.string(from: now)

        let metadata = TableMetadataRecord(
            tableName: "\(termName) (\(timeStamp))",
            semesterConfig: SemesterConfig(
                startDate: defaultConfig.startDate,
                weeks: inferredMaxWeek,
                visibleDays: visibleDays,
                periods: defaultConfig.periods
            ),
            isCurrent: true
        )
        return ParseResult(metadata: metadata, courses: courses)
    }

    // MARK: - 导出（直译 buildExportJson；无表/无课返回 nil）

    public static func buildExport(
        table: TableMetadataRecord, courses: [CourseRecord]
    ) -> String? {
        guard !courses.isEmpty else { return nil }

        var rowObjects: [String] = []
        for c in courses {
            var fields: [String] = []
            fields.append("\"name\": \(jsonString(c.name))")
            fields.append("\"dayOfWeek\": \(c.dayOfWeek)")
            fields.append("\"startPeriod\": \(c.startPeriod)")
            fields.append("\"endPeriod\": \(c.startPeriod + c.duration - 1)")
            let weeks = c.weekRule.value.sorted().map(String.init).joined(separator: ",")
            fields.append("\"weeks\": [\(weeks)]")
            if !c.teacher.isEmpty { fields.append("\"teacher\": \(jsonString(c.teacher))") }
            if !c.location.isEmpty { fields.append("\"location\": \(jsonString(c.location))") }
            if !c.note.isEmpty { fields.append("\"note\": \(jsonString(c.note))") }
            let indented = fields.map { "    \($0)" }.joined(separator: ",\n")
            rowObjects.append("    {\n\(indented)\n    }")
        }

        return "{\n  \"termName\": \(jsonString(table.tableName)),\n  \"rows\": [\n"
            + rowObjects.joined(separator: ",\n")
            + "\n  ]\n}"
    }

    // MARK: - 私有工具

    /// 字符串清理：空/字符串 "null" 视为 nil（对齐 cleanRaw + firstString 的组合语义）。
    private static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "null" { return nil }
        return trimmed
    }

    private static func firstStringClean(_ raw: String?) -> String? {
        clean(raw)
    }

    private static func firstInt(_ obj: [String: Any], _ key: String) -> Int? {
        guard let v = obj[key] else { return nil }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)).map(Int.init) }
        return nil
    }

    /// weeks 三态提取：数字数组 / 字符串数组（每项可含区间文本）/ 单字符串 / 单数字。
    private static func extractWeeks(_ obj: [String: Any]) -> [Int] {
        switch obj["weeks"] {
        case let list as [Any]:
            var result = Set<Int>()
            for w in list {
                if let n = w as? NSNumber {
                    result.insert(n.intValue)
                } else if let s = w as? String {
                    result.formUnion(parseWeekRange(s))
                }
            }
            return result.sorted()
        case let s as String:
            return s.trimmingCharacters(in: .whitespaces).isEmpty ? [] : parseWeekRange(s)
        case let n as NSNumber:
            return [n.intValue]
        default:
            return []
        }
    }

    /// JSON 字符串字面量（含转义；与 Android org.json 语义等价，互通以解析为准）。
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
