import Foundation
import GRDB

/// 数据库入口：WAL 池化 + 终态 schema 迁移注册。
/// 与 Android 端 `AppDatabase` 的差异：iOS 全新安装，不搬 v2→v14 迁移链，直接建终态 schema。
/// 平台中立：生产路径按宿主平台取标准数据目录，测试一律显式传路径或走 in-memory。
public struct DatabaseProvider: Sendable {
    /// 与 Android 端一致的库文件名。
    public static let databaseName = "app_database.sqlite"

    public let dbWriter: any GRDB.DatabaseWriter

    /// 生产入口：平台标准数据目录下的 DatabasePool（WAL）。
    public static func shared() throws -> DatabaseProvider {
        let directory = try defaultDatabaseDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent(databaseName)
        return try DatabaseProvider(databasePath: dbURL.path)
    }

    /// 指定路径构建（测试用临时文件路径验证 WAL 并发）。
    public init(databasePath: String) throws {
        var migrator = DatabaseMigrator()
        Migrations.registerAll(to: &migrator)
        dbWriter = try DatabasePool(path: databasePath, configuration: Self.configuration)
        try migrator.migrate(dbWriter)
    }

    /// 纯内存构建（单元测试默认入口）。
    public init(inMemory: Bool = true) throws {
        var migrator = DatabaseMigrator()
        Migrations.registerAll(to: &migrator)
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        dbWriter = queue
    }

    private static var configuration: Configuration {
        var config = Configuration()
        // GRDB 默认对每个连接开启 foreign_keys；显式声明以固化意图（对齐 Room 默认行为）。
        config.foreignKeysEnabled = true
        return config
    }

    public var pool: DatabasePool? {
        dbWriter as? DatabasePool
    }

    /// 平台标准数据目录：iOS = Documents；macOS = Application Support/OpenJWC。
    /// （macOS 上 App Store 沙箱归 App Support，非沙箱命令行测试也安全。）
    static func defaultDatabaseDirectory() throws -> URL {
        #if os(iOS)
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw DatabaseProviderError.documentsDirectoryUnavailable
        }
        return directory
        #else
        guard let home = ProcessInfo.processInfo.environment["HOME"] else {
            throw DatabaseProviderError.documentsDirectoryUnavailable
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/OpenJWC", isDirectory: true)
        #endif
    }
}

public enum DatabaseProviderError: Error {
    case documentsDirectoryUnavailable
}
