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
    }

    /// 启动路径：内置源播种（幂等；删除过的装回且默认不订阅）。
    func bootstrap() async {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Sources") else { return }
        let registry = SourceRegistry(db: db, settings: settings)
        if let result = try? await registry.syncBuiltIns(scriptDirectory: dir) {
            NSLog("SourceRegistry 播种完成：\(result.installed) 个源，跳过 \(result.skippedFiles.count) 个")
        }
    }
}
