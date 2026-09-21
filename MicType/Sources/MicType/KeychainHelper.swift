import Foundation
import Security

/// 把 OpenAI API Key 存在系统钥匙串里（不落明文文件）
enum KeychainHelper {
    private static let service = "com.ligen.mictype"
    /// 改名前（VoiceFlow 时代）的钥匙串条目，首次读取时自动迁移到新条目
    private static let legacyService = "com.ligen.voiceflow"

    /// 不传 account 时默认操作"当前选中的服务商"的 Key
    static func saveAPIKey(_ value: String, account: String? = nil) {
        let acct = account ?? Settings.shared.llmProvider.keychainAccount
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        deleteAPIKey(account: acct)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    /// 读取的替身。**App 里永远是 nil**，只有单测会装上它。
    ///
    /// 为什么值得一条生产代码里的缝：设置页的快照测试要渲染「云端 AI」那一页，而那一页
    /// 一登场就问"这一档有没有 Key"（KeyEntryView.load / CloudEditor.hasStoredKey）。
    /// 在 xctest 进程里问系统钥匙串是两种坏结果之一：要么拿到 nil（那这组截图就永远只有
    /// "还没填 Key"那个状态），要么弹一个授权框把整轮测试挂在那儿。
    /// 返回的字符串**只用来判"有没有"**，测试里塞的是一串假值。
    static var lookupOverride: ((String) -> String?)?

    static func loadAPIKey(account: String? = nil) -> String? {
        let acct = account ?? Settings.shared.llmProvider.keychainAccount
        if let override = lookupOverride { return override(acct) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let key = String(data: data, encoding: .utf8), !key.isEmpty {
            return key
        }
        // 新条目没有 → 尝试从旧 VoiceFlow 条目读取并自动迁移
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: acct,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var legacyResult: AnyObject?
        if SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult) == errSecSuccess,
           let data = legacyResult as? Data,
           let key = String(data: data, encoding: .utf8), !key.isEmpty {
            saveAPIKey(key, account: acct)   // 存入新条目，下次直接命中
            return key
        }
        return nil
    }

    static func deleteAPIKey(account: String? = nil) {
        let acct = account ?? Settings.shared.llmProvider.keychainAccount
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
