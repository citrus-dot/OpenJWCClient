import Foundation

/// 本地资讯工具集（结构化工具，不经过 Shell）。
/// 所有工具只读；返回文本会被 AgentLoop 按字节预算截断后再交给模型。
public final class AgentTools: Sendable {
    public static let toolSearch = "search_notices"
    public static let toolRead = "read_notice"
    public static let toolLabels = "list_labels"
    public static let toolSources = "list_sources"
    public static let toolTime = "current_time"
    public static let toolSourceStatus = "get_source_status"
    public static let toolDailyReport = "get_daily_report"
    public static let toolTimetable = "get_timetable"
    public static let toolTimetables = "list_timetables"
    public static let toolCoursesOn = "get_courses_on"
    public static let toolFindCourse = "find_course"

    /// 每页条数，与后端 VFS 一致。
    public static let pageSize = 20

    private static let maxReadChars = 12_000
    private static let defaultReadChars = 6_000
    private static let maxTitleChars = 200
    private static let maxQueryChars = 200
    private static let maxLabelChars = 100
    private static let maxSummaryChars = 600
    private static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    public let repository: any NoticeCorpus
    public let timetable: (any TimetableSource)?
    public let dailyReport: (any DailyReportSource)?
    private let timeZone: TimeZone

    public init(
        repository: any NoticeCorpus,
        timetable: (any TimetableSource)? = nil,
        dailyReport: (any DailyReportSource)? = nil,
        timeZone: TimeZone = .current
    ) {
        self.repository = repository
        self.timetable = timetable
        self.dailyReport = dailyReport
        self.timeZone = timeZone
    }

    /// 工具的中文名（UI 展示用）。
    public static func displayName(_ name: String) -> String {
        switch name {
        case toolSearch: return "检索资讯"
        case toolRead: return "阅读资讯"
        case toolLabels: return "查看栏目"
        case toolSources: return "查看数据源"
        case toolTime: return "查看当前时间"
        case toolSourceStatus: return "查看数据源状态"
        case toolDailyReport: return "查看日报"
        case toolTimetables: return "查看课表列表"
        case toolTimetable: return "查看课表"
        case toolCoursesOn: return "查看某天课程"
        case toolFindCourse: return "查找课程"
        default: return "工具"
        }
    }

    // MARK: - Specs（JSON Schema 字符串，内容逐字对齐 Android）

    private static let emptyParameters = #"{"type":"object","properties":{},"additionalProperties":false}"#

    private static func objectSchema(_ properties: String, required: [String] = []) -> String {
        var out = "{\"type\":\"object\",\"properties\":{" + properties + "}"
        if !required.isEmpty {
            let list = required.map { "\"\($0)\"" }.joined(separator: ",")
            out += ",\"required\":[" + list + "]"
        }
        out += ",\"additionalProperties\":false}"
        return out
    }

    private var noticeSpecs: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: Self.toolSearch,
                description: "检索本地资讯库：按关键词（同时匹配标题与正文）、栏目、数据源、日期范围筛选并分页。"
                    + "关键词可以是人名、老师、课程名、活动名、机构名等任意词。"
                    + "返回元数据（ID、日期、来源、栏目、标题），带关键词时**还会给出命中位置与正文片段**，"
                    + "可以直接据此判断相关性，不必逐条读正文。需要完整正文时再用 read_notice。",
                parameters: Self.objectSchema("""
                "query":{"type":"string","description":"关键词，会匹配标题与正文；留空表示只按条件列举"},
                "label":{"type":"string","description":"栏目名，可用 list_labels 查看"},
                "source_id":{"type":"string","description":"数据源 id 或名称，可用 list_sources 查看；留空表示不限"},
                "from":{"type":"string","description":"起始日期（含），格式 yyyy-MM-dd"},
                "to":{"type":"string","description":"结束日期（含），格式 yyyy-MM-dd"},
                "sort":{"type":"string","enum":["newest","relevance"],"description":"排序方式，默认 newest（最新优先）"},
                "page":{"type":"integer","minimum":1,"maximum":50,"description":"页码，每页 \(Self.pageSize) 条，默认 1"},
                "favorite":{"type":"boolean","description":"true 表示只看已收藏的资讯"}
                """)
            ),
            AgentToolSpec(
                name: Self.toolRead,
                description: "读取一条资讯的正文（可按字符偏移续读；也可用 keyword 只取命中段落）。"
                    + "正文含发布日期、官方链接与附件链接，附件内容未下载。",
                parameters: Self.objectSchema("""
                "id":{"type":"string","description":"资讯 ID（search_notices 返回）"},
                "offset":{"type":"integer","minimum":0,"description":"字符偏移，默认 0"},
                "limit":{"type":"integer","minimum":1,"maximum":\(Self.maxReadChars),"description":"读取字符数，默认 \(Self.defaultReadChars)"},
                "keyword":{"type":"string","description":"只在正文里找这个词，返回命中段落（最多 5 段）而不是整篇，省上下文"}
                """, required: ["id"])
            ),
            AgentToolSpec(
                name: Self.toolLabels,
                description: "列出本地资讯库的全部栏目及其条数。",
                parameters: Self.emptyParameters
            ),
            AgentToolSpec(
                name: Self.toolSources,
                description: "列出已订阅的数据源（id、名称、栏目、最近抓取时间）。",
                parameters: Self.emptyParameters
            ),
            AgentToolSpec(
                name: Self.toolTime,
                description: "返回当前日期时间（含时区），用于理解“今天/昨天”等自然日。",
                parameters: Self.emptyParameters
            ),
            AgentToolSpec(
                name: Self.toolSourceStatus,
                description: "查看已订阅数据源的运行状态：最近抓取时间、最近新增条数、抓取周期，以及最近一次失败原因。"
                    + "用户问“某个源怎么没更新/抓取失败了”时使用。",
                parameters: Self.emptyParameters
            ),
        ]
    }

    private var dailyReportSpec: AgentToolSpec {
        AgentToolSpec(
            name: Self.toolDailyReport,
            description: "读取本地已生成的日报（按天汇总的资讯摘要）。day 为 yyyy-MM-dd，留空表示今天；"
                + "只有已生成完成的日报才有内容，没有时如实说明。",
            parameters: Self.objectSchema("""
            "day":{"type":"string","description":"日期 yyyy-MM-dd，留空表示今天"}
            """)
        )
    }

    private var timetableSpecs: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: Self.toolTimetables,
                description: "列出用户本机保存的全部课表（ID、名称、学期起始、总周数、当前周、课程数），"
                    + "用于确认有哪些课表可选。",
                parameters: Self.emptyParameters
            ),
            AgentToolSpec(
                name: Self.toolTimetable,
                description: "读取某张课表的课程：课程名、教师、地点、星期、节次与上课周次。"
                    + "回答“今天/明天/这周有什么课”“某门课在哪上”等问题时使用；用户没有课表时会如实说明。",
                parameters: Self.objectSchema("""
                "table":{"type":"string","description":"课表名或 ID（可用 list_timetables 查看）；留空表示当前正在使用的那张"},
                "day":{"type":"integer","minimum":1,"maximum":7,"description":"只看星期几（1=周一 … 7=周日）；留空返回整周"}
                """)
            ),
            AgentToolSpec(
                name: Self.toolCoursesOn,
                description: "查看某一天有哪些课（含节次、地点、教师、周次）。"
                    + "回答“今天/明天/某天有什么课”时优先用它；date 可为 today / tomorrow / yyyy-MM-dd。"
                    + "table 留空表示在所有课表中查找（按各自学期自动匹配该日期并标明来源），填课表名/ID 则只查那一张。",
                parameters: Self.objectSchema("""
                "date":{"type":"string","description":"today / tomorrow / yyyy-MM-dd，留空表示今天"},
                "table":{"type":"string","description":"课表名或 ID；留空表示在所有课表中查找"}
                """)
            ),
            AgentToolSpec(
                name: Self.toolFindCourse,
                description: "在课表里按课程名、教师或地点查找课程，返回星期、节次、地点与周次。"
                    + "table 留空表示在所有课表中查找并标明来源，填课表名/ID 则只查那一张。",
                parameters: Self.objectSchema("""
                "query":{"type":"string","description":"课程名 / 教师 / 地点关键词"},
                "table":{"type":"string","description":"课表名或 ID；留空表示在所有课表中查找"}
                """, required: ["query"])
            ),
        ]
    }

    /// 实际暴露给模型的工具（没有课表不暴露课表工具，没有日报不暴露日报工具）。
    public var specs: [AgentToolSpec] {
        var all = noticeSpecs
        if dailyReport != nil { all.append(dailyReportSpec) }
        if timetable != nil { all.append(contentsOf: timetableSpecs) }
        return all
    }

    // MARK: - 元信息

    public func supports(_ name: String) -> Bool {
        specs.contains { $0.name == name }
    }

    /// 工具指向的本地对象 id（目前只有 read_notice 的资讯 id），用于 UI 跳转。
    public func targetId(_ name: String, _ arguments: String) -> String? {
        guard name == Self.toolRead,
              let obj = Self.parseObject(arguments),
              let id = Self.string(obj, "id")?.trimmingCharacters(in: .whitespaces),
              !id.isEmpty else { return nil }
        return id
    }

    /// 逐行列出所有参数的人类可读明细，用于工具卡片展示。
    public func summarize(_ name: String, _ arguments: String) async -> String {
        let obj = Self.parseObject(arguments)
        func str(_ key: String) -> String { Self.string(obj, key) ?? "" }
        func num(_ key: String) -> Int? { Self.int(obj, key) }
        func flag(_ key: String) -> Bool { Self.bool(obj, key) }

        var lines: [String] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { lines.append("\(label)：\(value)") }
        }

        switch name {
        case Self.toolSearch:
            add("关键词", str("query"))
            add("栏目", str("label"))
            let sourceRaw = str("source_id")
            if !sourceRaw.isEmpty {
                let sources = (try? await repository.subscribedSources()) ?? []
                let sourceName = sources.first { $0.id == sourceRaw }?.name
                add("数据源", sourceName ?? sourceRaw)
            }
            let from = str("from")
            let to = str("to")
            if !from.isEmpty || !to.isEmpty {
                add("日期", "\(from.isEmpty ? "不限" : from) ~ \(to.isEmpty ? "不限" : to)")
            }
            switch str("sort") {
            case "relevance": add("排序", "相关度优先")
            case "newest": add("排序", "最新优先")
            default: break
            }
            add("页码", num("page").map(String.init))
            if flag("favorite") { add("范围", "仅已收藏") }
            if lines.isEmpty { lines.append("列出资讯（无筛选条件）") }

        case Self.toolRead:
            let id = str("id")
            if !id.isEmpty {
                let title = (try? await repository.findNotice(id: id))??.title
                add("资讯", (title?.isEmpty == false) ? title! : "（本地未找到该资讯）")
            }
            add("只取关键词", str("keyword"))
            add("字符偏移", num("offset").map(String.init))
            add("读取字符数", num("limit").map(String.init))

        case Self.toolDailyReport:
            add("日期", str("day").isEmpty ? "今天" : str("day"))

        case Self.toolTimetable:
            add("课表", str("table").isEmpty ? "当前课表" : str("table"))
            if let day = num("day") {
                let weekday = day >= 1 && day <= 7 ? Self.weekdayNames[day - 1] : String(day)
                add("星期", "周\(weekday.hasPrefix("周") ? String(weekday.dropFirst()) : weekday)")
            }

        case Self.toolCoursesOn:
            add("日期", str("date").isEmpty ? "今天" : str("date"))
            add("课表", str("table").isEmpty ? "所有课表" : str("table"))

        case Self.toolFindCourse:
            add("关键词", str("query"))
            add("课表", str("table").isEmpty ? "所有课表" : str("table"))

        case Self.toolLabels:
            lines.append("列出全部栏目及条数")
        case Self.toolSources:
            lines.append("列出已订阅的数据源")
        case Self.toolTime:
            lines.append("获取当前日期时间")
        case Self.toolSourceStatus:
            lines.append("查看各数据源的运行状态")
        case Self.toolTimetables:
            lines.append("列出本机保存的全部课表")
        default:
            lines.append("执行工具")
        }
        return lines.joined(separator: "\n").prefix(Self.maxSummaryChars).description
    }

    // MARK: - 执行

    /// 执行工具；失败时抛出 AgentToolException。
    func execute(_ name: String, _ arguments: String) async throws -> String {
        guard let args = Self.parseObject(arguments) else {
            throw AgentToolException("tool_invalid_arguments", "工具参数不是合法 JSON")
        }
        switch name {
        case Self.toolSearch: return try await search(args)
        case Self.toolRead: return try await read(args)
        case Self.toolLabels: return try await listLabels()
        case Self.toolSources: return try await listSources()
        case Self.toolTime: return Self.currentTime(timeZone: timeZone)
        case Self.toolSourceStatus: return try await sourceStatus()
        case Self.toolDailyReport: return try await readDailyReport(args)
        case Self.toolTimetables: return try await listTimetables()
        case Self.toolTimetable: return try await readTimetable(args)
        case Self.toolCoursesOn: return try await coursesOn(args)
        case Self.toolFindCourse: return try await findCourse(args)
        default: throw AgentToolException("tool_unsupported", "未知工具: \(name)")
        }
    }

    // MARK: - 资讯工具

    private func search(_ args: [String: Any]) async throws -> String {
        let query = (Self.string(args, "query") ?? "").trimmingCharacters(in: .whitespaces).prefix(Self.maxQueryChars).description
        let label = (Self.string(args, "label") ?? "").trimmingCharacters(in: .whitespaces).prefix(Self.maxLabelChars).description
        let sourceNames = try await self.sourceNames()
        let sourceId = Self.resolveSourceId((Self.string(args, "source_id") ?? "").trimmingCharacters(in: .whitespaces), sourceNames)
        let from = (Self.string(args, "from") ?? "").trimmingCharacters(in: .whitespaces)
        let to = (Self.string(args, "to") ?? "").trimmingCharacters(in: .whitespaces)
        try Self.validateDay(from, "from")
        try Self.validateDay(to, "to")
        if !from.isEmpty && !to.isEmpty && from > to {
            throw AgentToolException("tool_invalid_arguments", "from 不能晚于 to")
        }
        let relevance = (Self.string(args, "sort") ?? "").trimmingCharacters(in: .whitespaces) == "relevance"
        let page = min(max(Self.int(args, "page") ?? 1, 1), 50)
        let favoriteOnly = Self.bool(args, "favorite")

        let total = try await repository.countNotices(
            query: query, label: label, sourceId: sourceId,
            fromDay: from, toDay: to, favoriteOnly: favoriteOnly
        )
        let items = try await repository.searchNotices(
            query: query, label: label, sourceId: sourceId, fromDay: from, toDay: to,
            favoriteOnly: favoriteOnly, relevance: relevance,
            limit: Self.pageSize, offset: (page - 1) * Self.pageSize
        )
        let pages = max(1, (total + Self.pageSize - 1) / Self.pageSize)
        let header = "共 \(total) 条；第 \(page)/\(pages) 页；排序 \(relevance ? "relevance" : "newest")。"
            + (items.isEmpty ? "没有结果，请换关键词、拆分词语或扩大日期范围。" : "")
        if items.isEmpty { return header }
        return Self.listing(items, sourceNames: sourceNames, query: query) + "\n" + header
    }

    private func read(_ args: [String: Any]) async throws -> String {
        let id = (Self.string(args, "id") ?? "").trimmingCharacters(in: .whitespaces)
        let keyword = (Self.string(args, "keyword") ?? "").trimmingCharacters(in: .whitespaces).prefix(Self.maxQueryChars).description
        if id.isEmpty || id.count > 256 {
            throw AgentToolException("tool_invalid_arguments", "资讯 ID 无效")
        }
        let offset = max(Self.int(args, "offset") ?? 0, 0)
        let limit = min(max(Self.int(args, "limit") ?? Self.defaultReadChars, 1), Self.maxReadChars)
        guard let notice = try await repository.findNotice(id: id) else {
            throw AgentToolException("tool_not_found", "资讯不存在: \(id)")
        }
        let sourceNames = try await self.sourceNames()

        var body = ""
        body += "ID: \(notice.id)\n"
        body += "标题: \(notice.title)\n"
        body += "来源: \(Self.sourceLabel(notice.sourceId, sourceNames))\n"
        body += "栏目: \(notice.label)\n"
        body += "发布日期: \(notice.publishedDay)\n"
        body += "官方链接: \(notice.detailUrl)\n"
        body += "\n"
        body += notice.content ?? ""
        body += "\n\n附件链接（未下载或解析内容）：\n"
        (notice.attachments?.value ?? []).forEach { body += "- \($0)\n" }

        if !keyword.isEmpty {
            let hits = Self.passages(notice.content ?? "", keyword)
            let header = body.components(separatedBy: "\n\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if hits.isEmpty {
                return "\(header)\n\n正文里没有出现「\(keyword)」。"
            }
            return "\(header)\n\n命中「\(keyword)」的段落：\n" + hits.joined(separator: "\n---\n")
        }

        let chars = Array(body)
        if offset >= chars.count {
            throw AgentToolException("tool_invalid_arguments", "字符偏移超过总长度 \(chars.count)")
        }
        let end = min(chars.count, offset + limit)
        let slice = String(chars[offset..<end])
        var suffix = "\n[字符 \(offset):\(end) / \(chars.count)]"
        if end < chars.count {
            suffix += "\n续读: read_notice(id=\"\(notice.id)\", offset=\(end), limit=\(limit))"
        } else {
            suffix += " EOF"
        }
        return slice + suffix
    }

    private func listLabels() async throws -> String {
        let labels = try await repository.corpusLabels()
        if labels.isEmpty { return "本地资讯库为空。" }
        var out = "共 \(labels.count) 个栏目：\n"
        for item in labels {
            out += "- \(item.label)（\(item.count) 条）\n"
        }
        return out
    }

    private func listSources() async throws -> String {
        let sources = try await repository.subscribedSources()
        if sources.isEmpty { return "没有已订阅的数据源。" }
        var out = "已订阅 \(sources.count) 个数据源：\n"
        for source in sources {
            out += "- id=\(source.id) 名称=\(source.name)"
            if !source.labels.value.isEmpty { out += " 栏目=\(source.labels.value.joined(separator: "、"))" }
            if let lastRunAt = source.lastRunAt { out += " 最近抓取=\(Self.formatInstant(lastRunAt, timeZone: timeZone))" }
            out += "\n"
        }
        return out
    }

    private func sourceStatus() async throws -> String {
        let sources = try await repository.subscribedSources()
        if sources.isEmpty { return "没有已订阅的数据源。" }
        var out = "已订阅 \(sources.count) 个数据源：\n"
        for source in sources {
            out += "- \(source.name)（\(source.id)）"
            out += " 周期 \(source.scheduleMinutes) 分钟"
            out += "；最近抓取 \(source.lastRunAt.map { Self.formatInstant($0, timeZone: timeZone) } ?? "从未")"
            out += "；最近新增 \(source.lastCount) 条"
            if let error = source.lastError {
                out += "；最近失败：\(error.split(separator: "\n").first.map(String.init) ?? error)"
            }
            out += "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readDailyReport(_ args: [String: Any]) async throws -> String {
        guard let source = dailyReport else {
            throw AgentToolException("tool_unsupported", "当前没有可读取的日报")
        }
        let raw = (Self.string(args, "day") ?? "").trimmingCharacters(in: .whitespaces)
        let day = raw.isEmpty ? Self.todayString() : raw
        guard Self.parseDay(day) != nil else {
            throw AgentToolException("tool_invalid_arguments", "day 日期格式应为 yyyy-MM-dd")
        }
        let content = try await source.completedReport(day: day)
        if content?.isEmpty != false {
            return "该日（\(day)）还没有已生成的日报。可以让用户在「日报」页生成，或改用 search_notices 检索当日资讯。"
        }
        return "日报 \(day)：\n\n\(content!)"
    }

    // MARK: - 课表工具

    private func listTimetables() async throws -> String {
        guard let source = timetable else {
            throw AgentToolException("tool_unsupported", "当前没有可读取的课表")
        }
        let all = try await source.timetables()
        if all.isEmpty { return "用户还没有配置课表。" }
        var out = "共 \(all.count) 张课表（ID、名称、学期起始、总周数、当前周、课程数）：\n"
        for snapshot in all {
            out += "- \(snapshot.id) \(snapshot.name)"
            out += "  起始 \(snapshot.startDate)"
            out += "，共 \(snapshot.totalWeeks) 周"
            out += "，\(snapshot.currentWeek.map { "当前第 \($0) 周" } ?? "不在学期内")"
            out += "，课程 \(snapshot.courses.count) 门"
            if snapshot.isCurrent { out += "（当前使用）" }
            out += "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readTimetable(_ args: [String: Any]) async throws -> String {
        guard let source = timetable else {
            throw AgentToolException("tool_unsupported", "当前没有可读取的课表")
        }
        let key = (Self.string(args, "table") ?? "").trimmingCharacters(in: .whitespaces)
        let snapshot: TimetableSnapshot?
        if key.isEmpty {
            snapshot = try await source.currentTimetable()
        } else {
            let all = try await source.timetables()
            snapshot = all.first { String($0.id) == key }
                ?? all.first { $0.name == key }
                ?? all.first { $0.name.localizedCaseInsensitiveContains(key) }
        }
        guard let snapshot else {
            return key.isEmpty ? "用户还没有配置课表。" : "没有找到名为「\(key)」的课表，可以先用 list_timetables 查看有哪些课表。"
        }
        let onlyDay = (Self.int(args, "day")).map { min(max($0, 1), 7) }
        let today = Date()
        var out = "课表：\(snapshot.name)\n"
        out += "学期起始：\(snapshot.startDate)，共 \(snapshot.totalWeeks) 周；"
        out += "\(snapshot.currentWeek.map { "当前第 \($0) 周" } ?? "当前不在学期内")\n"
        out += "今天：\(Self.dayString(today))（\(Self.weekdayName(today))）\n"

        if snapshot.courses.isEmpty {
            out += "\n课表里还没有课程。"
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let days = onlyDay.map { [$0] } ?? Array(1...7)
        for day in days {
            let ofDay = snapshot.courses
                .filter { $0.dayOfWeek == day }
                .sorted { $0.startPeriod < $1.startPeriod }
            if ofDay.isEmpty { continue }
            out += "\n\(Self.weekdayNames[day - 1])\n"
            for course in ofDay {
                out += "  第 \(course.startPeriod)"
                if course.duration > 1 { out += "-\(course.startPeriod + course.duration - 1)" }
                out += " 节  \(course.name)"
                if !course.location.isEmpty { out += "  \(course.location)" }
                if !course.teacher.isEmpty { out += "  \(course.teacher)" }
                out += "  \(Self.formatWeeks(course.weeks, snapshot.totalWeeks))"
                if !course.note.isEmpty { out += "  备注：\(course.note)" }
                out += "\n"
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func coursesOn(_ args: [String: Any]) async throws -> String {
        guard let source = timetable else {
            throw AgentToolException("tool_unsupported", "当前没有可读取的课表")
        }
        let key = (Self.string(args, "table") ?? "").trimmingCharacters(in: .whitespaces)
        var snapshots: [TimetableSnapshot]
        if key.isEmpty {
            let all = try await source.timetables()
            if all.isEmpty { throw AgentToolException("tool_not_found", "用户还没有配置课表") }
            snapshots = all
        } else {
            snapshots = [try await resolveTimetable(key)]
        }
        let date = try Self.parseDayArg((Self.string(args, "date") ?? "").trimmingCharacters(in: .whitespaces), timeZone: timeZone)
        let weekday = Self.weekdayName(date)
        let showTable = !key.isEmpty || snapshots.count > 1

        var blocks: [String] = []
        var outOfSemester: [String] = []
        for snapshot in snapshots {
            guard let week = Self.weekOf(snapshot, date, timeZone: timeZone) else {
                outOfSemester.append(snapshot.name)
                continue
            }
            let weekdayIndex = Self.weekdayIndex(date)
            let courses = snapshot.courses
                .filter { $0.dayOfWeek == weekdayIndex && $0.weeks.contains(week) }
                .sorted { $0.startPeriod < $1.startPeriod }
            if courses.isEmpty { continue }
            var block = ""
            if showTable { block += "课表「\(snapshot.name)」" }
            block += "第 \(week) 周：\n"
            for course in courses {
                block += "  - 第 \(course.startPeriod)"
                if course.duration > 1 { block += "-\(course.startPeriod + course.duration - 1)" }
                block += " 节  \(course.name)"
                if !course.location.isEmpty { block += "  \(course.location)" }
                if !course.teacher.isEmpty { block += "  \(course.teacher)" }
                block += "\n"
            }
            blocks.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let head = "\(Self.dayString(date))（\(weekday)）"
        if blocks.isEmpty {
            if outOfSemester.isEmpty {
                return "\(head) 没有课。"
            }
            return "\(head) 没有课（不在学期内的课表：\(outOfSemester.joined(separator: "、"))）。"
        }
        return head + "：\n" + blocks.joined(separator: "\n")
    }

    private func findCourse(_ args: [String: Any]) async throws -> String {
        guard let source = timetable else {
            throw AgentToolException("tool_unsupported", "当前没有可读取的课表")
        }
        let query = (Self.string(args, "query") ?? "").trimmingCharacters(in: .whitespaces).prefix(Self.maxQueryChars).description
        if query.isEmpty { throw AgentToolException("tool_invalid_arguments", "query 不能为空") }
        let key = (Self.string(args, "table") ?? "").trimmingCharacters(in: .whitespaces)
        var snapshots: [TimetableSnapshot]
        if key.isEmpty {
            let all = try await source.timetables()
            if all.isEmpty { throw AgentToolException("tool_not_found", "用户还没有配置课表") }
            snapshots = all
        } else {
            snapshots = [try await resolveTimetable(key)]
        }
        let needle = query.lowercased()
        let multi = snapshots.count > 1
        var lines: [String] = []
        for snapshot in snapshots {
            let matched = snapshot.courses
                .filter {
                    $0.name.lowercased().contains(needle)
                        || $0.teacher.lowercased().contains(needle)
                        || $0.location.lowercased().contains(needle)
                }
                .sorted { ($0.dayOfWeek, $0.startPeriod) < ($1.dayOfWeek, $1.startPeriod) }
            for course in matched {
                var line = "- "
                if multi { line += "「\(snapshot.name)」" }
                line += Self.weekdayNames[course.dayOfWeek - 1]
                line += " 第 \(course.startPeriod)"
                if course.duration > 1 { line += "-\(course.startPeriod + course.duration - 1)" }
                line += " 节  \(course.name)"
                if !course.location.isEmpty { line += "  \(course.location)" }
                if !course.teacher.isEmpty { line += "  \(course.teacher)" }
                line += "  \(Self.formatWeeks(course.weeks, snapshot.totalWeeks))"
                lines.append(line)
            }
        }
        if lines.isEmpty {
            return multi
                ? "所有课表里都没有匹配「\(query)」的课程。"
                : "课表「\(snapshots[0].name)」里没有匹配「\(query)」的课程。"
        }
        let header = multi ? "在所有课表里匹配「\(query)」的课程：" : "课表「\(snapshots[0].name)」匹配「\(query)」的课程："
        return header + "\n" + lines.joined(separator: "\n")
    }

    private func resolveTimetable(_ key: String) async throws -> TimetableSnapshot {
        guard let source = timetable else {
            throw AgentToolException("tool_unsupported", "当前没有可读取的课表")
        }
        if key.isEmpty {
            guard let current = try await source.currentTimetable() else {
                throw AgentToolException("tool_not_found", "用户还没有配置课表")
            }
            return current
        }
        let all = try await source.timetables()
        guard let found = all.first(where: { String($0.id) == key })
            ?? all.first(where: { $0.name == key })
            ?? all.first(where: { $0.name.localizedCaseInsensitiveContains(key) }) else {
            throw AgentToolException("tool_not_found", "没有找到名为「\(key)」的课表")
        }
        return found
    }

    // MARK: - 辅助（static 便于单测）

    private func sourceNames() async throws -> [String: String] {
        let sources = try await repository.subscribedSources()
        return Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.name) })
    }

    static func resolveSourceId(_ raw: String, _ names: [String: String]) -> String? {
        if raw.isEmpty { return nil }
        if names.keys.contains(raw) { return raw }
        return names.first { $0.value == raw }?.key ?? raw
    }

    static func sourceLabel(_ sourceId: String?, _ names: [String: String]) -> String {
        guard let sourceId, !sourceId.isEmpty else { return "未知来源" }
        return names[sourceId] ?? sourceId
    }

    static func currentTime(timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    static func formatInstant(_ epochMillis: Int64, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date(timeIntervalSince1970: Double(epochMillis) / 1000))
    }

    private static func todayString() -> String {
        dayString(Date())
    }

    static func dayString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    static func parseDay(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: value)
    }

    static func parseDayArg(_ raw: String, timeZone: TimeZone) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch raw.lowercased() {
        case "", "today", "今天":
            return Date()
        case "tomorrow", "明天":
            return calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        case "yesterday", "昨天":
            return calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        default:
            if let date = parseDay(raw) { return date }
            throw AgentToolException("tool_invalid_arguments", "日期格式应为 yyyy-MM-dd（或 today/tomorrow）")
        }
    }

    private static func weekdayName(_ date: Date) -> String {
        weekdayNames[Self.weekdayIndex(date) - 1]
    }

    static func weekdayIndex(_ date: Date, timeZone: TimeZone = .current) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let weekday = calendar.component(.weekday, from: date) // 1=周日
        return weekday == 1 ? 7 : weekday - 1
    }

    /// 某日期是学期第几周；不在学期内返回 nil（对齐 Android weekOf）。
    static func weekOf(_ snapshot: TimetableSnapshot, _ date: Date, timeZone: TimeZone) -> Int? {
        guard snapshot.totalWeeks > 0, let start = parseDay(snapshot.startDate) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        guard let startMonday = calendar.dateInterval(of: .weekOfYear, for: start)?.start,
              let endSunday = calendar.date(byAdding: .day, value: snapshot.totalWeeks * 7 - 1, to: startMonday),
              date >= startMonday, date <= endSunday else {
            return nil
        }
        let days = calendar.dateComponents([.day], from: startMonday, to: date).day ?? 0
        return min(max(days / 7 + 1, 1), snapshot.totalWeeks)
    }

    /// 周次的人类可读描述：每周 / 单周 / 双周 / 合并区间。
    static func formatWeeks(_ weeks: Set<Int>, _ totalWeeks: Int) -> String {
        if weeks.isEmpty { return "周次未指定" }
        let all = Set(1...max(totalWeeks, 1))
        if all.isSubset(of: weeks) { return "每周" }
        if weeks == Set(all.filter { $0 % 2 == 1 }) { return "单周" }
        if weeks == Set(all.filter { $0 % 2 == 0 }) { return "双周" }
        let sorted = weeks.sorted()
        var segments: [String] = []
        var i = 0
        while i < sorted.count {
            let start = sorted[i]
            var end = start
            while i + 1 < sorted.count && sorted[i + 1] == end + 1 {
                i += 1
                end = sorted[i]
            }
            segments.append(start == end ? "\(start)" : "\(start)-\(end)")
            i += 1
        }
        return segments.joined(separator: "、") + " 周"
    }

    /// 制表符分隔：ID、日期、来源、栏目、标题；带关键词时追加「命中位置 + 片段」。
    static func listing(_ items: [NoticeRecord], sourceNames: [String: String], query: String = "") -> String {
        items.map { notice -> String in
            var line = notice.id + "\t"
                + notice.publishedDay + "\t"
                + sourceLabel(notice.sourceId, sourceNames) + "\t"
                + String(notice.label.prefix(maxLabelChars)) + "\t"
                + String(notice.title.prefix(maxTitleChars))
            if !query.isEmpty, let info = matchInfo(notice, query) {
                line += "\t" + info
            }
            return line
        }.joined(separator: "\n")
    }

    /// 「命中位置｜片段」；未命中返回 nil。
    static func matchInfo(_ notice: NoticeRecord, _ query: String) -> String? {
        let inTitle = notice.title.range(of: query, options: .caseInsensitive) != nil
        let snippet = selfSnippet(notice.content, query)
        if !inTitle && snippet == nil { return nil }
        let whereText: String
        switch (inTitle, snippet != nil) {
        case (true, true): whereText = "标题+正文"
        case (true, false): whereText = "标题"
        default: whereText = "正文"
        }
        return snippet.map { "\(whereText)｜\($0)" } ?? whereText
    }

    /// 关键词附近的片段（折叠空白、两端补省略号）。
    static func selfSnippet(_ content: String?, _ query: String, radius: Int = 40) -> String? {
        guard let content, !content.isEmpty, !query.isEmpty else { return nil }
        guard let index = content.range(of: query, options: .caseInsensitive)?.lowerBound else { return nil }
        let idx = content.distance(from: content.startIndex, to: index)
        let start = max(idx - radius, 0)
        let end = min(idx + query.count + radius, content.count)
        let slice = String(Array(content)[start..<end])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (start > 0 ? "…" : "") + slice + (end < content.count ? "…" : "")
    }

    /// 正文里关键词出现的所有位置（最多 maxPassages 段）。
    static func passages(_ content: String, _ query: String, maxPassages: Int = 5, radius: Int = 120) -> [String] {
        if content.isEmpty || query.isEmpty { return [] }
        var result: [String] = []
        var searchStart = content.startIndex
        while result.count < maxPassages {
            guard let found = content.range(of: query, options: .caseInsensitive, range: searchStart..<content.endIndex) else { break }
            let idx = content.distance(from: content.startIndex, to: found.lowerBound)
            let start = max(idx - radius, 0)
            let end = min(idx + query.count + radius, content.count)
            let slice = String(Array(content)[start..<end])
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            result.append("[字符 \(start):\(end)] " + (start > 0 ? "…" : "") + slice + (end < content.count ? "…" : ""))
            if found.upperBound >= content.endIndex { break }
            searchStart = found.upperBound
        }
        return result
    }

    static func validateDay(_ value: String, _ field: String) throws {
        if value.isEmpty { return }
        if parseDay(value) == nil {
            throw AgentToolException("tool_invalid_arguments", "\(field) 日期格式应为 yyyy-MM-dd")
        }
    }

    static func parseObject(_ arguments: String) -> [String: Any]? {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    static func string(_ obj: [String: Any]?, _ key: String) -> String? {
        obj?[key] as? String
    }

    static func int(_ obj: [String: Any]?, _ key: String) -> Int? {
        obj?[key] as? Int ?? (obj?[key] as? String).flatMap(Int.init)
    }

    static func bool(_ obj: [String: Any]?, _ key: String) -> Bool {
        obj?[key] as? Bool ?? false
    }
}
