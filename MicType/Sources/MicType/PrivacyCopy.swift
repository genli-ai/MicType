import Foundation

// MARK: - 隐私与费用文案（唯一出处）

/// 「录音边说边传 / 还有哪些文字跟着走 / 不留存 / Key 在钥匙串 / 费用直付服务商 /
/// OpenAI 走 Fast 档 / 听写历史仅本机」这几句话
/// 以前在关于页、引导欢迎页、引导结束页各写一遍，措辞还都不一样——用户读到三种说法，
/// 只能靠猜哪一句算数；改一次文案就得记得去另外两处同步，漏一处就自相矛盾（v4.0 调研 §1.12 / C10）。
///
/// 所以写成一处常量：**所有界面都引用这里的句子，不再各自造词**。
/// 三条硬约束：
///   • 必须是计算属性（`var` 而不是 `let`）——`tr()` 要在渲染时求值，否则切换界面语言不刷新；
///   • 句子刻意写短（一行装得下）：关于页与引导页都是固定高度，长句一换行就把下面的内容挤出窗口；
///   • 只陈述事实，不作承诺：每一句都对应一条能在代码里指出来的行为。
enum PrivacyCopy {

    /// 录音去了哪里。**5.0.0 起这句话反过来了**：本机识别整条链路删掉了，
    /// 识别只有云端一条路（设计文档第 1 节），所以再写"默认本地、音频不出机"就是骗人。
    ///
    /// 两件事必须写进去，少一件用户就会误判：
    ///   • **边说边传**，不是"录完再传"——按下热键就连上，你说话的同时音频就在往服务商去
    ///     （这样松手才能 0.25–1 秒出结果）；
    ///   • 于是 Esc 的语义是"立刻停止上传"，而**已经传出去的那几秒收不回来**。
    ///     不写这一句，用户会以为按 Esc 等于什么都没发生过。
    ///
    /// 名字仍然叫 audioStaysLocal 会自相矛盾，所以改名 audioGoesToProvider；
    /// 引导第一屏与关于页引用的都是这一个出处。
    static var audioGoesToProvider: String {
        tr("录音与识别都在你选的服务商那边完成：你说话的同时音频就在往上传，按 Esc 会立刻停止，但已经传出去的部分收不回来。",
           "Recording and recognition both happen at the provider you picked: audio goes up while you are still speaking. Esc stops it at once, but whatever already left cannot be taken back.")
    }

    /// 出门的是哪些文字。
    ///
    /// **不能只说"只有识别出的文字"**：那句话在主功能路径上就不成立。真正跟着请求走的还有
    /// 词汇表与自定义规则（润色与指令两条路都带，PolishService / AgentService 各自拼进 prompt），
    /// 以及指令模式下**从前台应用读到的选区原文**——那常常是别人发来的消息、一封邮件、
    /// 一段文档，压根不是用户自己口述的内容。
    /// 用户按这句话判断"什么东西会离开这台 Mac"，所以它必须把选区点名说出来。
    /// （4.1.1 起「关于我」已经并进「自定义规则」，不再单列一项。）
    ///
    /// 5.0.0 去掉了"开了润色或语音指令"这个前提：润色永远开着，这句话无条件成立。
    static var onlyTextLeaves: String {
        tr("除了录音，跟着一起发出去的还有：识别出的文字、你选中的那段文字、词汇表和自定义规则。",
           "Besides the audio, what also goes out is: the recognized text, any text you selected, your vocabulary and your custom rules.")
    }

    /// 留存那一句。**必须按当前生效的那一档说**，因为 `store: false` 只存在于 Responses 的请求体里
    /// （AgentService.responsesBody），而那条路只有「OpenAI 档 + 官方域名」才走
    /// （LLMClient.usesResponsesAPI）。阿里云、以及把 Base URL 改指向第三方网关的 OpenAI 档，
    /// 走的都是 chat/completions —— 那个请求体里一个留存字段都没有。
    /// 对着这些用户说"请求带 store:false 发出"，就是承诺了一件代码没做的事。
    ///
    /// 纯函数版本供单测把三态钉死：判据必须和 `LLMClient.usesResponsesAPI` 同一个。
    static func retention(provider: LLMProvider, baseURL: String) -> String {
        if provider == .openai, LLMClient.usesResponsesAPI(baseURL: baseURL) {
            return tr("请求带 store:false 发出，服务商不留存这些请求。",
                      "Requests go out with store:false, so the provider keeps no copy.")
        }
        return tr("这一档没有「不留存」开关：这些请求留多久由这家服务商自己的政策决定。",
                  "This provider has no no-retention switch: how long it keeps these requests is governed by its own policy.")
    }

    /// 当前这台机器上的那一句（界面用）
    static var retentionLine: String {
        let provider = Settings.shared.llmProvider
        return retention(provider: provider, baseURL: Settings.shared.baseURL(for: provider))
    }

    /// Key 只在钥匙串里：不进设置文件、不随导出走（SettingsBackup 从不导出 Key）。
    ///
    /// **句子本身不在这里写**：同一件事在 Key 输入框那颗 ⓘ 里也要说，而那一处的唯一出处是
    /// LLMCatalog.keyStorageNote。两边各写一版的结果是关于页说"不写进文件"、设置页说
    /// "加密、仅本机可读"——改一处漏一处就自相矛盾。和 webSearchBilled 同一条做法：引用，不复述。
    static var keyInKeychain: String { LLMCatalog.keyStorageNote }

    /// 费用直付服务商：MicType 不代理请求。同上——Key 输入框下面那一行价格用的是同一个出处
    /// （LLMCatalog.billingNote；4.3.2 起设置页里它住在 API Key 那颗 ⓘ 里）。
    static var youPayProvider: String { LLMCatalog.billingNote }

    /// 联网搜索 5.0.0 起**没有开关、永远开**（支持的服务商）。界面上既然没有那个开关，
    /// 这一句就是它唯一的交代——所以它比从前更该在这儿。
    /// **单价不在这里写**：出处只有 LLMCatalog.webSearchPriceNote 一个。
    static var webSearchBilled: String {
        tr("按住说指令时允许联网搜索（没有开关，永远开）：",
           "Hold-to-command may search the web (always on, no switch): ") + LLMCatalog.webSearchPriceNote
    }

    /// Fast 档：4.1.6 起 OpenAI 官方接口的每一次请求都带 `service_tier:"fast"`，
    /// 界面上没有开关（用户 2026-09-21 拍板）。**多花的钱必须有一处写着**——就是这一句。
    ///
    /// 三件事刻意这么写：
    ///   • **单价不在这里写**：出处只有 LLMCatalog.fastTierPriceNote 一个（引用，不复述），
    ///     和 webSearchBilled 同一条做法；
    ///   • **点名"官方接口"**：把 OpenAI 档的 Base URL 指向第三方网关时一个字都不发
    ///     （判据见 LLMClient.asksForFastTier），写成无条件的"OpenAI 的请求"就是假话；
    ///   • **不按当前服务商分支**：这一句陈述的是 App 的行为（"OpenAI 走哪一档"），
    ///     不是"你这台机器这会儿在花什么钱"——retention 那句才是按生效档现算的。
    static var fastTier: String {
        tr("OpenAI 官方接口的请求一律走 Fast 档：", "Requests to the official OpenAI API always use the Fast tier: ")
            + LLMCatalog.fastTierPriceNote
    }

    /// 听写历史：**存在这台 Mac 上，不上传**。5.0.0 起这一句格外要紧——
    /// 别的东西都去云端了，用户很容易以为历史也跟着上去了，所以它进了这张表。
    ///
    /// **句子本身不在这里写**：存哪儿、留多少条、上不上传的唯一出处是
    /// HistoryStore.storageNote（条数就是那个常量）。和 keyInKeychain 引用
    /// LLMCatalog.keyStorageNote 同一条做法：引用，不复述——4.3.6 之前关于页正是
    /// 把它单独又渲染了一遍，于是同一件事在同一屏上出现两次、措辞还不一样。
    static var historyStaysLocal: String { HistoryStore.storageNote }

    /// 数据流向那两句：讲"东西去了哪里"，引导第一屏用
    static var dataFlowLines: [String] { [audioGoesToProvider, onlyTextLeaves] }

    /// Key 与费用那几句：讲"谁收你的钱、Key 放在哪、什么东西没出去"（关于页用）。
    /// 第一句按当前生效的服务商现算（见 retention），不是一句放之四海的承诺。
    static var keyAndCostLines: [String] {
        [retentionLine, keyInKeychain, youPayProvider, webSearchBilled, fastTier, historyStaysLocal]
    }

    /// 完整八句，顺序固定（关于页用）。顺序本身是文案的一部分：
    /// 先说数据去哪，再说钱谁收，最后说什么东西留在了本机
    static var allLines: [String] { dataFlowLines + keyAndCostLines }
}
