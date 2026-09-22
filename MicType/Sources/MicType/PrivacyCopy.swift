import Foundation

// MARK: - 隐私与费用文案（唯一出处）

/// 「音频不出机 / 只发文字 / 不留存 / Key 在钥匙串 / 费用直付服务商 / 搜索按次计费」这六句话
/// 以前在关于页、引导欢迎页、引导结束页各写一遍，措辞还都不一样——用户读到三种说法，
/// 只能靠猜哪一句算数；改一次文案就得记得去另外两处同步，漏一处就自相矛盾（v4.0 调研 §1.12 / C10）。
///
/// 所以写成一处常量：**所有界面都引用这里的句子，不再各自造词**。
/// 三条硬约束：
///   • 必须是计算属性（`var` 而不是 `let`）——`tr()` 要在渲染时求值，否则切换界面语言不刷新；
///   • 句子刻意写短（一行装得下）：关于页与引导页都是固定高度，长句一换行就把下面的内容挤出窗口；
///   • 只陈述事实，不作承诺：每一句都对应一条能在代码里指出来的行为。
enum PrivacyCopy {

    /// 录音与识别默认全在本机（Qwen3-ASR / MLX）。
    /// v4.0 起多了一档**可选**的云端识别，所以这句话必须把边界说全：
    /// 不能再写成无条件的"音频不出这台 Mac"（那会变成一句在云端档下不成立的承诺），
    /// 也不能改成含糊的"可能会上传"（默认档下音频确实一个字节都不出去）。
    ///
    /// 4.1.7 起后半句要写得更狠一点：那一档已经不是"录完再传"了——按下热键就连上，
    /// **你说话的同时**音频就在往阿里云去（这样松手才能 0.25 秒出结果）。
    /// 于是 Esc 的语义也变了：它立刻停止上传，但已经传出去的那几秒**收不回来**。
    /// 不写这一句，用户会以为按 Esc 等于什么都没发生过。
    static var audioStaysLocal: String {
        tr("默认本地识别：录音与识别都在这台 Mac 上完成，只有选择云端引擎时音频才会上传——那一档是你说话的同时就在传，按 Esc 会立刻停止，但已经传出去的部分收不回来。",
           "On-device recognition by default: recording and recognition run on this Mac; audio is uploaded only if you choose a cloud engine - and then it goes up while you are still speaking. Esc stops it at once, but whatever already left cannot be taken back.")
    }

    /// 出门的是哪些文字。
    ///
    /// **不能只说"只有识别出的文字"**：那句话在主功能路径上就不成立。真正跟着请求走的还有
    /// 词汇表与自定义规则（润色与指令两条路都带，PolishService / AgentService 各自拼进 prompt），
    /// 以及指令模式下**从前台应用读到的选区原文**——那常常是别人发来的消息、一封邮件、
    /// 一段文档，压根不是用户自己口述的内容。
    /// 用户按这句话判断"什么东西会离开这台 Mac"，所以它必须把选区点名说出来。
    /// （4.1.1 起「关于我」已经并进「自定义规则」，不再单列一项。）
    static var onlyTextLeaves: String {
        tr("开了润色或语音指令，发给服务商的是识别出的文字，外加你选中的那段文字、词汇表和自定义规则。",
           "With polish or voice commands on, what goes to your provider is the recognized text plus any text you selected, your vocabulary and your custom rules.")
    }

    /// 留存那一句。**必须按当前生效的那一档说**，因为 `store: false` 只存在于 Responses 的请求体里
    /// （AgentService.responsesBody），而那条路只有「OpenAI 档 + 官方域名」才走
    /// （LLMClient.usesResponsesAPI）。DeepSeek、Qwen、自定义网关、以及把 Base URL 改指向
    /// 第三方网关的 OpenAI 档，全部走 chat/completions —— 那个请求体里一个留存字段都没有。
    /// 对着这些用户说"请求带 store:false 发出"，就是承诺了一件代码没做的事。
    ///
    /// 纯函数版本供单测把三态钉死：判据必须和 `LLMClient.usesResponsesAPI` 同一个。
    static func retention(provider: LLMProvider, baseURL: String) -> String {
        if provider == .local {
            // 本机模型：请求根本不出这台 Mac，"服务商留不留存"这个问题不存在
            return tr("本机模型：润色与指令都在这台 Mac 上跑，请求不出网。",
                      "On-device model: polish and commands run on this Mac, so no request leaves it.")
        }
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

    /// 联网搜索是显式付费开关，4.1.1 起默认**开**（支持的服务商）。
    /// **单价不在这里写**：它只有一个出处 LLMCatalog.webSearchPriceNote（设置页开关旁用的是
    /// 同一句）。以前这里自己写了一遍「约每 1000 次 10 美元」，改一次价就会有两句话打架。
    static var webSearchBilled: String {
        tr("联网搜索：", "Web search: ") + LLMCatalog.webSearchPriceNote
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

    /// 数据流向那两句：讲"东西去了哪里"，引导第一屏用
    static var dataFlowLines: [String] { [audioStaysLocal, onlyTextLeaves] }

    /// Key 与费用那五句：讲"谁收你的钱、Key 放在哪"（关于页用）。
    /// 第一句按当前生效的服务商现算（见 retention），不是一句放之四海的承诺。
    static var keyAndCostLines: [String] {
        [retentionLine, keyInKeychain, youPayProvider, webSearchBilled, fastTier]
    }

    /// 完整七句，顺序固定（关于页用）。顺序本身是文案的一部分：先说数据去哪，再说钱谁收
    static var allLines: [String] { dataFlowLines + keyAndCostLines }

    // MARK: - 云端识别的代价在哪儿说

    /// **不在这里**。关于页与引导页讲的是默认状态，而云端识别是用户另点出来的一档——
    /// 它的上传、计费、留存、先开通模型、出错回落，全部写在做这个选择的地方那颗 ⓘ 里
    /// （SettingsCopy.cloudRecognitionInfo）。同一个事实仍然只写一处，只是那一处不是这里：
    /// 这六句是"打开 MicType 就成立"的承诺，云端那几句只有开着那个开关才成立。
}
