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

    /// 第三句：**Key 与钱**。5.0.2 把两句并成一句（用户 2026-09-23 拍板：关于页文字减半）——
    /// 「Key 只在钥匙串」和「费用直付、MicType 不经手」说的是同一件事的两头：
    /// 我们既不拿你的 Key，也不碰你的钱。
    ///
    /// **两截都逐字引用 LLMCatalog**（全 App 唯一出处）：Key 输入框那颗 ⓘ 里念的是同一串，
    /// 各写一版的结果是关于页说"不写进文件"、设置页说"加密、仅本机可读"。
    static var keyAndBilling: String {
        LLMCatalog.keyStorageNote + tr("", " ") + LLMCatalog.billingNote
    }

    // 5.0.2 删掉的三句（用户 2026-09-23 拍板，关于页文字减半）：
    //   • 留存（retention / retentionLine）——它按生效服务商分三种说法，而用户在这一页
    //     要的是"什么东西出了门"，不是每一家的留存政策；
    //   • 联网搜索计费、OpenAI Fast 档——这两句讲的是**花钱**，它们的半句话搬进了
    //     Key 那一行的 ⓘ（SettingsCopy.keyInfo：那里本来就在说这一档一小时多少钱）；
    //   • 听写历史仅本机（historyStaysLocal）——它现在是「保存听写历史」那个开关自己的 ⓘ
    //     （SettingsCopy.behaviourInfo），就在开关旁边，比在六句话里排第六管用。

    /// 数据流向那两句：讲"东西去了哪里"
    static var dataFlowLines: [String] { [audioGoesToProvider, onlyTextLeaves] }

    /// Key 与费用：5.0.2 起只有一句（见 keyAndBilling）
    static var keyAndCostLines: [String] { [keyAndBilling] }

    /// 完整**三句**，顺序固定（关于页用）。顺序本身是文案的一部分：
    /// 先说录音去哪，再说还有什么跟着走，最后说钱和 Key。
    /// 5.0.2 从八句压到三句：八句摆在一屏上，结果是一句都没人读。
    static var allLines: [String] { dataFlowLines + keyAndCostLines }
}
