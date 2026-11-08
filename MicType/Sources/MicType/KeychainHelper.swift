import Foundation
import Security

/// 钥匙串的四个系统调用。生产里是 `SystemKeychainBackend`（直通 SecItem*），
/// 单测换成内存字典——这样「存 Key → 发通知 → 有人回头读 Key」这条链能在测试里真跑，
/// 不碰用户的系统钥匙串。参数就是 SecItem* 的查询字典，原样转交
protocol KeychainBackend {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?)
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainBackend: KeychainBackend {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// 把 OpenAI API Key 存在系统钥匙串里（不落明文文件）
///
/// 铁规矩（5.4.2，用户 MacBook Air 上三次复现的崩溃）：**读路径绝不发 `keysChangedNotification`**。
/// 旧版 `loadAPIKey` 在新条目缺失时把旧 VoiceFlow 条目「迁移」过来，迁移走的是 `saveAPIKey`，
/// 而 `saveAPIKey` 先删新条目、删完就发通知；`AppDelegate` 收到通知同步 `loadAPIKey` →
/// 新条目刚被删 → 又去迁旧条目 → 又删、又发通知……无限递归、栈溢出，真正的 `SecItemAdd`
/// 永远轮不到。症状：Key 验证 200，`API key verified` 那行日志不出现，App 崩溃，
/// 重启后钥匙串里又是旧 Key（启动时那次读把旧条目安静地迁回来了）。
/// 现在：迁移直接写新条目、写成功就删旧条目；保存「先写到位再说」，通知只在末尾发一次
enum KeychainHelper {
    private static let service = "com.ligen.mictype"
    /// 改名前（VoiceFlow 时代）的钥匙串条目，首次读取时自动迁移到新条目
    private static let legacyService = "com.ligen.voiceflow"

    /// 生产里永远是系统钥匙串；只有单测会换成内存实现
    static var backend: KeychainBackend = SystemKeychainBackend()

    /// 钥匙串里的 Key 存了 / 删了（5.4.0：菜单栏图标的「没有 Key」红点据此重查一次，
    /// 不去轮询钥匙串）。只说"变了"，不带 Key、不带账户名
    static let keysChangedNotification = Notification.Name("MicTypeKeychainKeysChanged")

    private static func itemQuery(service svc: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account,
        ]
    }

    /// 只读一个条目，不迁移、不发通知
    private static func read(service svc: String, account: String) -> String? {
        var query = itemQuery(service: svc, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = backend.copyMatching(query)
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// 删一个条目；没有这一条也算成功。日志只带状态码和账户名
    @discardableResult
    private static func remove(service svc: String, account: String) -> Bool {
        let status = backend.delete(itemQuery(service: svc, account: account))
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        Log.warn("Keychain delete failed status=\(status) account=\(account)")
        return false
    }

    /// 不传 account 时默认操作"当前选中的服务商"的 Key。
    ///
    /// 返回值 = 钥匙串里现在确实是这把 Key（写完读回比对过）。顺序是「先写到位」：
    /// update 优先、没有条目才 add、add 撞上重复再 update 一次——中途失败时原来那把还在，
    /// 不会像旧版「先删后写」那样写失败就两头落空。空串 = 删除
    @discardableResult
    static func saveAPIKey(_ value: String, account: String? = nil) -> Bool {
        let acct = account ?? Settings.shared.llmProvider.keychainAccount
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return deleteAPIKey(account: acct) }
        defer { postKeysChanged() }   // 成功失败都发一次，让红点刷新
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query = itemQuery(service: service, account: acct)
        let changes: [String: Any] = [kSecValueData as String: data]
        var status = backend.update(query, changes)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            status = backend.add(attributes)
            if status == errSecDuplicateItem {
                status = backend.update(query, changes)
            }
        }
        guard status == errSecSuccess else {
            Log.warn("Keychain save failed status=\(status) account=\(acct)")
            return false
        }
        guard read(service: service, account: acct) == trimmed else {
            Log.warn("Keychain save failed status=readbackMismatch account=\(acct)")
            return false
        }
        // 新 Key 已经到位，旧 VoiceFlow 条目留着只会在新条目哪天被删时又被「迁移」回来
        remove(service: legacyService, account: acct)
        return true
    }

    private static func postKeysChanged() {
        let post = { NotificationCenter.default.post(name: keysChangedNotification, object: nil) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    /// 读取的替身。**App 里永远是 nil**，只有单测会装上它。
    ///
    /// 为什么值得一条生产代码里的缝：设置页的快照测试要渲染「云端 AI」那一页，而那一页
    /// 一登场就问"这一档有没有 Key"（KeyEntryView.load / MainSettingsPage.hasStoredKey）。
    /// 在 xctest 进程里问系统钥匙串是两种坏结果之一：要么拿到 nil（那这组截图就永远只有
    /// "还没填 Key"那个状态），要么弹一个授权框把整轮测试挂在那儿。
    /// 返回的字符串**只用来判"有没有"**，测试里塞的是一串假值。
    static var lookupOverride: ((String) -> String?)?

    static func loadAPIKey(account: String? = nil) -> String? {
        let acct = account ?? Settings.shared.llmProvider.keychainAccount
        if let override = lookupOverride { return override(acct) }
        if let key = read(service: service, account: acct) { return key }
        // 新条目没有 → 尝试从旧 VoiceFlow 条目读取并迁移。
        // 只直接写新条目、不走 saveAPIKey、不发通知（见类型注释里的递归崩溃）
        guard let key = read(service: legacyService, account: acct),
              let data = key.data(using: .utf8) else { return nil }
        var attributes = itemQuery(service: service, account: acct)
        attributes[kSecValueData as String] = data
        let status = backend.add(attributes)
        if status == errSecSuccess {
            remove(service: legacyService, account: acct)
            Log.info("Keychain legacy entry migrated account=\(acct)")
        } else {
            Log.warn("Keychain legacy migration failed status=\(status) account=\(acct)")
        }
        return key
    }

    /// 新旧两个条目一起删：只删新条目的话，下一次读会把旧 VoiceFlow 条目「迁移」回来，
    /// 用户清掉的 Key 自己复活。返回值 = 两条都已不在
    @discardableResult
    static func deleteAPIKey(account: String? = nil) -> Bool {
        let acct = account ?? Settings.shared.llmProvider.keychainAccount
        let current = remove(service: service, account: acct)
        let legacy = remove(service: legacyService, account: acct)
        postKeysChanged()
        return current && legacy
    }
}
