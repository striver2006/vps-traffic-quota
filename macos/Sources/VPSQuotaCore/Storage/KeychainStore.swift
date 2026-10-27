import Foundation
import Security

/// 各服务商 API Key 的存放处。
///
/// 密钥不进 config.json —— 配置文件是明文且用户可能会拷贝/备份它。
/// 对应 Windows 端的 DPAPI(`ProtectedData`) 实现。
public enum KeychainStore {
    private static let service = "io.vpsquota.VPSTrafficQuota"
    private static let vultrAccount = "vultr-api-key"
    /// 搬瓦工的 Key 是按 VEID（即按服务器）发的，一条钥匙串项里存
    /// 「serverId → apiKey」的 JSON 字典，增删服务器时整体重写。
    private static let bwgAccount = "bwg-api-keys"

    public enum KeychainError: LocalizedError {
        case failed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .failed(let status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "钥匙串访问失败：\(msg)"
            }
        }
    }

    public static func vultrAPIKey() throws -> String? {
        try read(account: vultrAccount)
    }

    public static func setVultrAPIKey(_ key: String?) throws {
        try write(account: vultrAccount, value: key)
    }

    /// serverId → KiwiVM API Key。没存过或内容坏了都返回 nil（当「没设置」处理）。
    public static func bwgAPIKeys() throws -> [String: String]? {
        guard let raw = try read(account: bwgAccount) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
    }

    /// 整体重写。空字典等价于删除整条钥匙串项。
    public static func setBwgAPIKeys(_ keys: [String: String]) throws {
        let trimmed = keys.filter { !$0.value.isEmpty }
        guard !trimmed.isEmpty else {
            try write(account: bwgAccount, value: nil)
            return
        }
        let data = try JSONEncoder().encode(trimmed)
        try write(account: bwgAccount, value: String(data: data, encoding: .utf8))
    }

    private static func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.failed(status)
        }
        return String(data: data, encoding: .utf8)
    }

    /// 传 nil 或空串表示删除该条目。
    private static func write(account: String, value: String?) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.failed(status)
            }
            return
        }

        let data = Data(value.utf8)
        // 先尝试更新已有条目，不存在再新增。
        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.failed(updateStatus)
        }

        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.failed(addStatus)
        }
    }
}
