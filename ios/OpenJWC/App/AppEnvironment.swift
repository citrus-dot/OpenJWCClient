import Foundation
import GRDB
import OpenJWCCore

/// D-1 组合根：App 进程内装配一次（DB → DAO → 服务 → stores）。
/// 装配与 store 状态都在主线程（@MainActor），DB/脚本重活由 core 层自行离主线程。
/// 阶段 5 的 Agent/LLM 装配在此扩展，不在视图层散建依赖。
@MainActor
@Observable
final class AppEnvironment {
    let db: any DatabaseWriter
    let settings: SettingsStore
    let noticeDao: NoticeDao
    let sourceDao: SourceDao
    let reactive: ReactiveStore
    let news: NewsStore
    let crawl: CrawlCoordinator
    let chat: ChatStore
    let dailyReport: DailyReportStore
    let motto: MottoStore
    let timetable: TimetableStore

    init() throws {
        let provider = try DatabaseProvider.shared()
        self.db = provider.dbWriter
        self.settings = SettingsStore()
        self.noticeDao = NoticeDao(db: db)
        self.sourceDao = SourceDao(db: db)
        self.reactive = ReactiveStore(db: db)
        self.news = NewsStore(db: db, settings: settings)

        let crawlService = NewsCrawlService(db: db) { source in
            // 内置脚本来自 bundle 的 folder reference（D-5）：Sources/<scriptFile>
            guard let file = source.scriptFile,
                  let dir = Bundle.main.resourceURL?.appendingPathComponent("Sources") else {
                throw ScriptError.execution("缺少脚本文件信息")
            }
            return try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
        }
        self.crawl = CrawlCoordinator(service: crawlService)

        let runtime = AgentRuntime(settings: settings, db: db)
        self.chat = ChatStore(db: db, runtime: runtime)
        let reportService = DailyReportService(db: db) {
            runtime.makeLoop()
        }
        self.dailyReport = DailyReportStore(db: db, service: reportService)
        self.motto = MottoStore(settings: settings)
        self.timetable = TimetableStore(db: db, settings: settings)
    }

    /// 启动路径：内置源播种（幂等；删除过的装回且默认不订阅）。
    func bootstrap() async {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Sources") else { return }
        let registry = SourceRegistry(db: db, settings: settings)
        if let result = try? await registry.syncBuiltIns(scriptDirectory: dir) {
            NSLog("SourceRegistry 播种完成：\(result.installed) 个源，跳过 \(result.skippedFiles.count) 个")
        }
        #if DEBUG
        // 6a 手验：-startTimetable 且无任何课表时，建表 + 注入示例课程（6b 编辑器到位后移除）
        if ProcessInfo.processInfo.arguments.contains("-startTimetable") {
            let dao = TimetableDao(db: db)
            let isEmpty = (try? await dao.allTables().isEmpty) ?? false
            if isEmpty {
                let service = TimetableService(db: db)
                let tableId = (try? await service.createTable(TimetableJson.defaultTable())) ?? 0
                for (day, name) in [(1, "高等数学"), (3, "大学物理"), (5, "体育")] {
                    _ = try? await dao.insertCourse(CourseRecord(
                        id: nil, tableId: tableId, name: name, teacher: "张老师", location: "教一-101",
                        dayOfWeek: day, startPeriod: day == 5 ? 6 : 1, duration: 2,
                        color: TimetableJson.deterministicColor(for: name),
                        weekRule: JSONIntSet(Set(1...16)), note: ""
                    ))
                }
            }
        }
        #endif
        migrateLegacyLlmConfig()
    }

    /// 旧单配置（provider_config + Key 按 providerId）→ 配置档案（幂等）。
    /// 把旧 Key 搬到 profile 隔离键下，避免升级后要求重填。
    private func migrateLegacyLlmConfig() {
        guard settings.loadProfiles().isEmpty else { return }
        let legacy = settings.loadLlmConfig()
        let isNewish = legacy != LlmProviderConfig()
        let profile = LlmProfile(
            name: LlmPresets.byId(legacy.providerId).name,
            config: legacy,
            isActive: true
        )
        settings.saveProfiles([profile])
        let key = try? LlmKeyStore().load(for: legacy.providerId)
        if isNewish, let key = key ?? nil, !key.isEmpty {
            try? LlmKeyStore().save(key, for: AgentRuntime.keyAccount(profile.id))
        }
        NSLog("LLM 配置已迁移为配置档案：\(profile.name)")
    }
}
