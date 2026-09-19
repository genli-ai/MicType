import Foundation

// MARK: - 云端识别用到的钥匙串账号
//
// 故意写成 extension 放在独立文件里：KeychainHelper.swift 一个字都不用改（别的分支也在动它，
// 零 diff 就零冲突）。已有的 saveAPIKey/loadAPIKey/deleteAPIKey 本来就收 account 参数，
// 这里只是把云端那两个账号名固定下来。

extension KeychainHelper {

    /// 阿里云百炼（DashScope）的 Key，自己一份
    static let dashScopeAccount = "dashscope_api_key"
    /// OpenAI 云端识别复用润色那把 Key（同一个账号条目，不重复让用户填）
    static let openAIAccount = "openai_api_key"

    static func loadDashScopeKey() -> String? { loadAPIKey(account: dashScopeAccount) }
    static func saveDashScopeKey(_ value: String) { saveAPIKey(value, account: dashScopeAccount) }
    static func deleteDashScopeKey() { deleteAPIKey(account: dashScopeAccount) }

    /// 按云端供应商取 Key（没有就是 nil，引擎据此判"不可用"）
    static func loadCloudASRKey(for provider: CloudASRProvider) -> String? {
        loadAPIKey(account: provider.keychainAccount)
    }
}
