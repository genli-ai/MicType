import XCTest
import Security
@testable import MicType

/// 内存钥匙串：按 service + account 存字典。只认 KeychainHelper 实际用到的那几个键
private final class MemoryKeychain: KeychainBackend {
    var items: [String: Data] = [:]
    var addStatusOverride: OSStatus?
    var updateStatusOverride: OSStatus?

    private func key(_ q: [String: Any]) -> String {
        "\(q[kSecAttrService as String] as? String ?? "")|\(q[kSecAttrAccount as String] as? String ?? "")"
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        if let s = addStatusOverride { return s }
        let k = key(attributes)
        if items[k] != nil { return errSecDuplicateItem }
        items[k] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        guard let d = items[key(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, d as NSData)
    }
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        if let s = updateStatusOverride { return s }
        let k = key(query)
        guard items[k] != nil else { return errSecItemNotFound }
        items[k] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
    }
    func value(_ service: String, _ account: String) -> String? {
        items["\(service)|\(account)"].flatMap { String(data: $0, encoding: .utf8) }
    }
    func put(_ service: String, _ account: String, _ value: String) {
        items["\(service)|\(account)"] = value.data(using: .utf8)
    }
}

final class KeychainHelperTests: XCTestCase {
    private let account = "openai_api_key"
    private let newService = "com.ligen.mictype"
    private let legacyService = "com.ligen.voiceflow"
    private var memory: MemoryKeychain!
    private var savedBackend: KeychainBackend!
    private var observers: [NSObjectProtocol] = []

    override func setUp() {
        super.setUp()
        memory = MemoryKeychain()
        savedBackend = KeychainHelper.backend
        KeychainHelper.backend = memory
        KeychainHelper.lookupOverride = nil
    }

    override func tearDown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        KeychainHelper.backend = savedBackend
        super.tearDown()
    }

    /// 5.4.1 崩溃的原样复现：只有旧 VoiceFlow 条目 + 一个收到通知就读 Key 的观察者（AppDelegate 的红点）
    func testSaveWithLegacyEntryAndReadingObserverDoesNotRecurse() {
        memory.put(legacyService, account, "sk-old")
        var notifications = 0
        observers.append(NotificationCenter.default.addObserver(
            forName: KeychainHelper.keysChangedNotification, object: nil, queue: nil) { [account] _ in
            notifications += 1
            XCTAssertLessThan(notifications, 10, "keysChanged 通知在递归")
            _ = KeychainHelper.loadAPIKey(account: account)
        })

        XCTAssertTrue(KeychainHelper.saveAPIKey("sk-new", account: account))
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(KeychainHelper.loadAPIKey(account: account), "sk-new")
        XCTAssertNil(memory.value(legacyService, account))
    }

    func testFirstLoadMigratesLegacyEntrySilently() {
        memory.put(legacyService, account, "sk-old")
        var notifications = 0
        observers.append(NotificationCenter.default.addObserver(
            forName: KeychainHelper.keysChangedNotification, object: nil, queue: nil) { _ in
            notifications += 1
        })

        XCTAssertEqual(KeychainHelper.loadAPIKey(account: account), "sk-old")
        XCTAssertEqual(memory.value(newService, account), "sk-old")
        XCTAssertNil(memory.value(legacyService, account))
        XCTAssertEqual(notifications, 0, "读路径不许发 keysChanged")
    }

    func testMigrationWriteFailureStillReturnsLegacyKeyAndKeepsIt() {
        memory.put(legacyService, account, "sk-old")
        memory.addStatusOverride = errSecInteractionNotAllowed
        XCTAssertEqual(KeychainHelper.loadAPIKey(account: account), "sk-old")
        XCTAssertEqual(memory.value(legacyService, account), "sk-old")
    }

    func testSaveFailureKeepsPreviousKey() {
        memory.put(newService, account, "sk-previous")
        memory.updateStatusOverride = errSecInteractionNotAllowed
        memory.addStatusOverride = errSecInteractionNotAllowed
        XCTAssertFalse(KeychainHelper.saveAPIKey("sk-new", account: account))
        XCTAssertEqual(memory.value(newService, account), "sk-previous")
    }

    func testSaveFailureWithNoEntryReturnsFalse() {
        memory.addStatusOverride = errSecInteractionNotAllowed
        XCTAssertFalse(KeychainHelper.saveAPIKey("sk-new", account: account))
        XCTAssertNil(KeychainHelper.loadAPIKey(account: account))
    }

    func testSaveReplacesExistingKey() {
        memory.put(newService, account, "sk-previous")
        XCTAssertTrue(KeychainHelper.saveAPIKey("  sk-new \n", account: account))
        XCTAssertEqual(memory.value(newService, account), "sk-new")
    }

    func testSavingEmptyStringDeletesBothEntries() {
        memory.put(newService, account, "sk-current")
        memory.put(legacyService, account, "sk-old")
        XCTAssertTrue(KeychainHelper.saveAPIKey("   ", account: account))
        XCTAssertNil(memory.value(newService, account))
        XCTAssertNil(memory.value(legacyService, account))
        XCTAssertNil(KeychainHelper.loadAPIKey(account: account))
    }
}
