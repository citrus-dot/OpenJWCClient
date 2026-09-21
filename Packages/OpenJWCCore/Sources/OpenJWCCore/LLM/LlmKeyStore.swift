import Foundation
import Security

/// LLM API Key 的 Keychain 存储（对位 Android `LlmKeyStore`/EncryptedSharedPreferences）。
///
/// - `service` 固定，`account = providerId`：per-provider 多 Key 结构。
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：后台任务（阶段 7 抓取/日报）
///   在锁屏下运行，`WhenUnlocked` 会读不到；`ThisDeviceOnly` 保证不随 iCloud 迁移泄漏。
/// - 空串视为未设置（对齐 Android `takeIf { it.isNotBlank() }`）。
/// - Key 值不得出现在任何日志中；错误只报 OSStatus。
public struct LlmKeyStore {
    public static let service = "OpenJWC.llm-keys"

    public init() {}

    public func save(_ key: String, for providerId: String) throws {
        let base = baseQuery(providerId: providerId)
        // Keychain 无原生 upsert：先删再加。
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
    }

    public func load(for providerId: String) throws -> String? {
        var query = baseQuery(providerId: providerId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        // 空串视为未设置（对齐 Android）。
        return key.isEmpty ? nil : key
    }

    public func delete(for providerId: String) {
        SecItemDelete(baseQuery(providerId: providerId) as CFDictionary)
    }

    private func baseQuery(providerId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: providerId,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

public enum KeychainError: Error {
    case osStatus(OSStatus)
}
