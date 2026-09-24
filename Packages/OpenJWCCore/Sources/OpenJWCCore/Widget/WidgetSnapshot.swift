import Foundation
import GRDB

/// App Group 共享约定（design D-7）：主 app 写、小组件读的两键 + 容器标识。
/// user_settings 不迁移（D-7 决策）——小组件只读这里的独立键。
public enum WidgetSharedKeys {
    public static let appGroupId = "group.org.openjwc.shared"
    /// 相对 App Group 容器的背景图路径（空 = 无背景）。
    public static let backgroundPathKey = "widget.backgroundPath"
    /// 背景不透明度 0...1（默认 0.5 = Android 128/255 换算）。
    public static let backgroundOpacityKey = "widget.backgroundOpacity"
    public static let defaultOpacity = 0.5
    /// 背景图文件名（存容器根）。
    public static let backgroundFileName = "widget-background.jpg"
    /// 小组件 timeline kind（reloadTimelines(ofKind:) 用；与 CourseWidget StaticConfiguration 一致）。
    public static let widgetKind = "org.openjwc.course"
}

/// 课表快照（App Group 共享数据模型，design D-7）：
/// 主 App 导出（表元数据 + 节次配置 + 全部课程）→ JSON 原子写容器；
/// 小组件/课程提醒读取后本地计算，不触达数据库。单写多读，读侧宽容解码。
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// schema 版本：读侧遇到更高版本按空态回退（宽容）。
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var tableId: Int64
    public var tableName: String
    /// 学期第一天（yyyy-MM-dd，对齐 SemesterConfig.startDate）。
    public var startDate: String
    public var totalWeeks: Int
    /// 节次起止分钟表（HH:mm，数组下标 = 节号-1）。
    public var periods: [Period]
    public var courses: [Course]

    public struct Period: Codable, Equatable, Sendable {
        /// HH:mm。
        public var start: String
        /// HH:mm。
        public var end: String

        public init(start: String, end: String) {
            self.start = start
            self.end = end
        }
    }

    public struct Course: Codable, Equatable, Sendable {
        public var id: Int64
        public var name: String
        public var teacher: String
        public var location: String
        /// ISO 星期：周一=1 … 周日=7。
        public var dayOfWeek: Int
        public var startPeriod: Int
        public var duration: Int
        /// ARGB 数值（与 Android Color.toArgb() 同一位模式，可能为负）。
        public var color: Int64
        public var weekRule: Set<Int>

        public init(
            id: Int64, name: String, teacher: String, location: String,
            dayOfWeek: Int, startPeriod: Int, duration: Int, color: Int64,
            weekRule: Set<Int>
        ) {
            self.id = id
            self.name = name
            self.teacher = teacher
            self.location = location
            self.dayOfWeek = dayOfWeek
            self.startPeriod = startPeriod
            self.duration = duration
            self.color = color
            self.weekRule = weekRule
        }
    }

    public init(
        schemaVersion: Int = WidgetSnapshot.currentSchemaVersion,
        tableId: Int64, tableName: String, startDate: String,
        totalWeeks: Int, periods: [Period], courses: [Course]
    ) {
        self.schemaVersion = schemaVersion
        self.tableId = tableId
        self.tableName = tableName
        self.startDate = startDate
        self.totalWeeks = totalWeeks
        self.periods = periods
        self.courses = courses
    }
}

// MARK: - JSON 编解码（宽容读）

extension WidgetSnapshot {
    /// 容错解码：文件不存在/缺字段/未知版本 → nil（调用方回退空态，不崩溃）。
    public static func decode(_ data: Data) -> WidgetSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return nil
        }
        // 未知（更高）版本回退空态；低于 1 不可能出现但同样按空态处理
        guard snapshot.schemaVersion == WidgetSnapshot.currentSchemaVersion else {
            return nil
        }
        return snapshot
    }

    /// 从文件读快照（宽容）：不存在/损坏 → nil。
    public static func read(from url: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    public func encodeJSON() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// 原子写（Data.write(.atomic) 自带临时文件 + rename 语义，防半截快照被小组件读到）。
    /// 返回是否成功。
    @discardableResult
    public func write(to url: URL) -> Bool {
        guard let data = encodeJSON() else { return false }
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 快照文件名约定（App Group 容器内）。
    public static let snapshotFileName = "timetable-snapshot.json"

    /// 容器目录 → 快照文件 URL。
    public static func snapshotURL(containerURL: URL) -> URL {
        containerURL.appendingPathComponent(snapshotFileName)
    }
}

// MARK: - DB 记录 → 快照转换（课程提醒排程与小组件导出共用）

extension WidgetSnapshot {
    /// 从课表元数据 + 课程列表构建快照（节次顺序 = SemesterConfig.periods 顺序）。
    public init(table: TableMetadataRecord, courses: [CourseRecord]) {
        let config = table.semesterConfig
        self.init(
            tableId: table.id ?? 0,
            tableName: table.tableName,
            startDate: config.startDate,
            totalWeeks: config.weeks,
            periods: config.periods.map { Period(start: $0.start, end: $0.end) },
            courses: courses.map { course in
                Course(
                    id: course.id ?? 0,
                    name: course.name,
                    teacher: course.teacher,
                    location: course.location,
                    dayOfWeek: course.dayOfWeek,
                    startPeriod: course.startPeriod,
                    duration: course.duration,
                    color: course.color,
                    weekRule: course.weekRule.value
                )
            }
        )
    }
}
