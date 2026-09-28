import Foundation

// MARK: - 云端识别用到的钥匙串账号
//
// 故意写成 extension 放在独立文件里：KeychainHelper.swift 一个字都不用改（别的分支也在动它，
// 零 diff 就零冲突）。已有的 saveAPIKey/loadAPIKey/deleteAPIKey 本来就收 account 参数，
// 这里只是把云端那两个账号名固定下来。
//
// **云端识别复用润色那一档的 Key**，不再各存一份：让用户为同一个控制台里的同一把 Key
// 粘两遍，只会粘出两份不一致的值（改了一处、另一处还是旧的，表现是随机 401）。
//
// 5.1.0 删掉了阿里云那一档（连同 4.x 开发期旧账号的搬家函数）：它的两条钥匙串条目
// 由启动时的 RetiredProviderCleanup 删除，**绝不**搬到 OpenAI 的账号上。

extension KeychainHelper {

    /// OpenAI 云端识别复用润色那把 Key（同一个账号条目，不重复让用户填）
    static let openAIAccount = LLMProvider.openai.keychainAccount

    /// 按云端供应商取 Key（没有就是 nil，引擎据此判"不可用"）
    static func loadCloudASRKey(for provider: CloudASRProvider) -> String? {
        loadAPIKey(account: provider.keychainAccount)
    }
}
