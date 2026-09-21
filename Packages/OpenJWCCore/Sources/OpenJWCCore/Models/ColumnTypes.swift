import Foundation
import GRDB

// MARK: - JSON 列包装类型（对齐 Android Converters 的宽容回退语义）

/// `[String]` 列：JSON 文本存储，解析失败回退空数组（对齐 Android `Converters.toStringList`）。
public struct JSONStringList: Codable, DatabaseValueConvertible, Equatable, Sendable {
    public var value: [String] = []

    public init(_ value: [String] = []) {
        self.value = value
    }

    // 自定义 Codable：JSON 列是顶层数组（对齐 Android kotlinx 序列化），
    // 避免 GRDB Codable 路径把合成 init 当对象解码。
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode([String].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public var databaseValue: DatabaseValue {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "[]".databaseValue
        }
        return text.databaseValue
    }

    public static func from(databaseValue: DatabaseValue) -> Self? {
        guard let text = databaseValue.storage.value as? String else { return nil }
        guard let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return JSONStringList([])
        }
        return JSONStringList(list)
    }
}

/// `Set<Int>` 列：JSON 数组文本存储（对齐 Android `Converters.toIntSet`，课表 weekRule 用）。
struct JSONIntSet: Codable, DatabaseValueConvertible, Equatable {
    var value: Set<Int> = []

    init(_ value: Set<Int> = []) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = Set(try container.decode([Int].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value.sorted())
    }

    var databaseValue: DatabaseValue {
        let ordered = value.sorted()
        guard let data = try? JSONEncoder().encode(ordered),
              let text = String(data: data, encoding: .utf8) else {
            return "[]".databaseValue
        }
        return text.databaseValue
    }

    static func from(databaseValue: DatabaseValue) -> Self? {
        guard let text = databaseValue.storage.value as? String else { return nil }
        guard let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode([Int].self, from: data) else {
            return JSONIntSet([])
        }
        return JSONIntSet(Set(list))
    }
}
