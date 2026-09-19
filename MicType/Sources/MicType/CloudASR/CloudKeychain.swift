import Foundation

// MARK: - 云端识别用到的钥匙串账号
//
// 故意写成 extension 放在独立文件里：KeychainHelper.swift 一个字都不用改（别的分支也在动它，
// 零 diff 就零冲突）。已有的 saveAPIKey/loadAPIKey/deleteAPIKey 本来就收 account 参数，
// 这里只是把云端那两个账号名固定下来。
//
// **两家云端都复用润色那一档的 Key**，不再各存一份：
//   • 阿里云百炼（DashScope）的 Key 一把就管住润色和识别两件事，让用户为同一个控制台里的
//     同一把 Key 粘两遍，只会粘出两份不一致的值（改了一处、另一处还是旧的，表现是随机 401）。
//   • OpenAI 同理。
// 区域设置（qwenRegion / qwenWorkspaceID）跟着一起共用，理由见 CloudASRSettings.alibabaRegion。

extension KeychainHelper {

    /// 阿里云百炼（DashScope）的 Key —— 与 LLMProvider.qwen 同一条钥匙串条目
    static let dashScopeAccount = LLMProvider.qwen.keychainAccount
    /// OpenAI 云端识别复用润色那把 Key（同一个账号条目，不重复让用户填）
    static let openAIAccount = LLMProvider.openai.keychainAccount

    /// v4.0 开发期间云端识别一度自己存一份（"dashscope_api_key"）。合并成一把之后，
    /// 那条旧条目要搬过来再删掉：否则用户在识别页填过的 Key 会凭空消失一次。
    static let legacyDashScopeAccount = "dashscope_api_key"

    /// 启动时调一次：把旧账号里的 Key 搬到统一账号上。
    /// **只在统一账号还空着时搬**——已经有值的那把是用户后来填的，绝不拿旧值盖掉它
    /// （"永不用空值/旧值覆盖已存 Key" 是 623d603 起的老规矩）。
    static func migrateLegacyDashScopeKey() {
        guard legacyDashScopeAccount != dashScopeAccount else { return }
        guard let legacy = loadAPIKey(account: legacyDashScopeAccount),
              !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let current = loadAPIKey(account: dashScopeAccount),
           !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleteAPIKey(account: legacyDashScopeAccount)
            Log.info("Cloud ASR key migration: unified account already set, dropped the legacy entry")
            return
        }
        saveAPIKey(legacy, account: dashScopeAccount)
        deleteAPIKey(account: legacyDashScopeAccount)
        Log.info("Cloud ASR key migrated to the shared DashScope account")
    }

    /// 按云端供应商取 Key（没有就是 nil，引擎据此判"不可用"）
    static func loadCloudASRKey(for provider: CloudASRProvider) -> String? {
        loadAPIKey(account: provider.keychainAccount)
    }
}
