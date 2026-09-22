import Foundation
import Security

/// LLM API Key 的密钥存储（对位 Android `LlmKeyStore`/EncryptedSharedPreferences）。
///
/// - 主存储 Keychain：`service` 固定，`account` = 调用方给定的隔离键
///   （旧单配置 = providerId；多配置档案 = profile id）。
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：后台任务（阶段 7 抓取/日报）
///   在锁屏下运行，`WhenUnlocked` 会读不到；`ThisDeviceOnly` 保证不随 iCloud 迁移泄漏。
/// - **回退存储**：免签名构建（模拟器 CODE_SIGNING_ALLOWED=NO）没有
///   keychain-access-groups entitlement，Keychain 写入返回 errSecMissingEntitlement——
///   此时回退到独立 UserDefaults suite（明文，仅本地开发场景）；真机侧载有签名走 Keychain。
/// - 空串视为未设置（对齐 Android `takeIf { it.isNotBlank() }`）。
/// - Key 值不得出现在任何日志中；错误只报 OSStatus。
public struct LlmKeyStore {
    public static let service = "OpenJWC.llm-keys"
    private static let fallbackSuite = "OpenJWC.llm-keys-fallback"

    public init() {}

    private var fallback: UserDefaults {
        UserDefaults(suiteName: Self.fallbackSuite) ?? .standard
    }

    public func save(_ key: String, for account: String) throws {
        if key.isEmpty {
            delete(for: account)
            return
        }
        let base = baseQuery(account: account)
        // Keychain 无原生 upsert：先删再加。
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return }
        // Keychain 不可用（典型：模拟器免签名构建）→ 回退 UserDefaults
        fallback.set(key, forKey: fallbackKey(account))
    }

    public func load(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data, let key = String(data: data, encoding: .utf8),
           !key.isEmpty {
            return key
        }
        // Keychain 未命中/不可用 → 查回退存储
        return fallback.string(forKey: fallbackKey(account)).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func delete(for account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        fallback.removeObject(forKey: fallbackKey(account))
    }

    /// 清空回退存储中的全部 Key（登出/重置场景用）。
    public func wipeFallback() {
        fallback.removePersistentDomain(forName: Self.fallbackSuite)
    }

    private func fallbackKey(_ account: String) -> String {
        "key-\(account)"
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

public enum KeychainError: Error {
    case osStatus(OSStatus)
}
