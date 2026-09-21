import Foundation
import GRDB

/// 数据源注册表：内置脚本播种（对齐 Android `SourceRegistry.syncBuiltIns`）。
/// iOS 内置脚本以 folder reference 打包在 app bundle 的 `Sources/` 目录；
/// 阶段 4 不含侧载（sideload）编辑器，来源编辑器留到设置阶段。
public struct SourceRegistry: Sendable {
    /// 新装/新增内置源时默认订阅的唯一源（教务处）。
    public static let defaultSubscribedId = "seu-jwc"
    public static let originBuiltIn = "builtin"

    private let db: any DatabaseWriter
    private let settings: SettingsStore

    public init(db: any DatabaseWriter, settings: SettingsStore) {
        self.db = db
        self.settings = settings
    }

    /// 播种结果。
    public struct SyncResult: Equatable, Sendable {
        /// 成功播种的源数。
        public var installed: Int
        /// 因缺少 @id 被跳过的文件名。
        public var skippedFiles: [String]
    }

    /// 把目录里的内置脚本同步进数据库；保留用户已设置的 subscribed / 运行结果（幂等）。
    /// 已记录于 `deletedSourceIds` 的源重新装回但默认不订阅，并清除该删除记录（对齐 Android）。
    public func syncBuiltIns(scriptDirectory: URL) async throws -> SyncResult {
        let fileManager = FileManager.default
        let fileNames = (try? fileManager.contentsOfDirectory(atPath: scriptDirectory.path))?
            .filter { $0.lowercased().hasSuffix(".js") }
            .sorted() ?? []

        var deleted = settings.loadDeletedSourceIds()
        var installed = 0
        var skipped: [String] = []
        let dao = SourceDao(db: db)

        for fileName in fileNames {
            let url = scriptDirectory.appendingPathComponent(fileName)
            guard let script = try? String(contentsOf: url, encoding: .utf8),
                  let manifest = ScriptManifestParser.parse(script) else {
                skipped.append(fileName)
                continue
            }

            // 老版本允许删除内置源：重新装回，但恢复出来的默认不订阅
            let wasDeleted = deleted.contains(manifest.id)
            if wasDeleted {
                deleted.remove(manifest.id)
            }

            let existing = try await dao.getById(id: manifest.id)
            let record = NoticeSourceRecord(
                id: manifest.id,
                name: manifest.name,
                version: manifest.version,
                origin: Self.originBuiltIn,
                scriptFile: fileName,
                domains: JSONStringList(manifest.domains),
                labels: JSONStringList(manifest.labels),
                scheduleMinutes: manifest.scheduleMinutes,
                subscribed: existing?.subscribed ?? (!wasDeleted && manifest.id == Self.defaultSubscribedId),
                lastRunAt: existing?.lastRunAt,
                lastCount: existing?.lastCount ?? 0,
                lastError: existing?.lastError
            )
            try await dao.upsert(record)
            installed += 1
        }

        if deleted != settings.loadDeletedSourceIds() {
            settings.saveDeletedSourceIds(deleted)
        }
        return SyncResult(installed: installed, skippedFiles: skipped)
    }

    /// 内置源脚本全文（`scriptFile` 是目录内文件名）。
    public static func scriptText(of source: NoticeSourceRecord, in directory: URL) -> String? {
        guard let file = source.scriptFile else { return nil }
        return try? String(
            contentsOf: directory.appendingPathComponent(file),
            encoding: .utf8
        )
    }
}
