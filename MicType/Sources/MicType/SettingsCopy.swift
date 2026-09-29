import Foundation

// MARK: - 设置窗口的全部文字（唯一出处 + 硬预算）

/// Plan C 的文案预算写在这里，并且**由单测钉死**（SettingsCopyBudgetTests）。
///
/// 为什么非得收进一个文件：4.0.1 的设置页每个控件下面都挂着两三行解释，于是真正的控件被挤到
/// 第二屏、第三屏，而那些解释一天要被同一个人读一百遍。问题不在某一句写长了，而在于
/// **没有任何东西拦得住下一句**——文案散在各个视图里，谁也看不出这一页一共说了多少字。
///
/// 三条预算（数字就是测试里的断言）：
///   • 每个控件至多一行说明，中文 ≤ 16 字、英文 ≤ 60 字符（`captions`）；
///   • 细则一律收进段头那颗 ⓘ，中文 ≤ 120 字（`infos`）；
///   • 单个编辑页的说明字数合计 ≤ 200 字（`inputCaptions` / `recognitionCaptions` / `cloudCaptions`）。
///
/// 两类文字**不在**这张表里，而且是故意的：
///   • **价格**（LLMCatalog.webSearchPriceNote / fastTierPriceNote / billingNote…）——它们是
///     代价而不是解释，必须摆在开关旁边，绝不许被"太长了"挤进 ⓘ；出处也只有 LLMCatalog 一个。
///   • **一次性状态快照**（验证结论、下载进度、导入导出结果）——那是结果，不是文案。
///
/// 边界状态（`boundary…`）另算一条线：一行结论 + 一颗按钮，所以按"一行"量（中文 ≤ 34 字），
/// 但永远不许写成一段话。
enum SettingsCopy {

    /// 控件说明那条线的数字本身（中文 ≤ 16 字 / 英文 ≤ 60 字符）。
    /// 放在这里是因为**渲染层也要用它**：识别模型那一行说明来自可远端更新的模型目录，
    /// 目录里写多长我们管不着，只能在渲染时照同一条线截断——单测量的是同一个数字
    /// （SettingsCopyBudgetTests 断言两边相等）。
    static var captionLimit: Int { L10n.shared.language == .zh ? 16 : 60 }

    // 「输入」页 5.0.0 整页没有了（设置只剩一页）：快捷键那一行、界面语言、开机自启
    // 三样连同它们的说明一起撤掉——键只有右 Option 一颗（引导第一屏教过）、语言在菜单栏切、
    // 开机自启在引导 ⑤ 注册（要关去系统设置的登录项）。词汇表与自定义规则搬进「专有词汇表」。

    /// 「保存听写历史」那一行的 ⓘ。
    ///
    /// **5.0.2 改短并接下了那句隐私陈述**：关于页的隐私段压到三句，而"存哪儿、不上传"
    /// 只在这个开关旁边说才有用。事实本身仍然只有一个出处（HistoryStore.storageNote），
    /// 这里只在它后面补一句"关掉之后怎样"。
    static var behaviourInfo: String {
        HistoryStore.storageNote + tr("关掉即停止记录，已有的记录不动。",
                                      " Turning this off stops recording and leaves existing entries alone.")
    }

    /// 5.1.0 去掉了「服务商与接入地址」：只剩 OpenAI 一家，阿里云的接入地址也没了。
    /// 仍然会被导入改掉的只有 OpenAI 的接口地址（openaiBaseURL），所以说"接口地址"。
    static var backupInfo: String {
        tr("导出一个 JSON：词汇表、自定义规则、接口地址、界面语言。导入是合并，别人给的文件可能把接口地址换掉（会提示一次）。API Key 从不导出、也从不导入。",
           "Exports one JSON file: vocabulary, custom rules, endpoint and the interface language. Import merges, and a file from someone else can change your endpoint (the summary says so). API keys are never exported or imported.")
    }

    // rulesNeedAI 5.0.0 删掉：没有「只用本地」那一档了，自定义规则永远会被发出去。

    /// 「专有词汇表」那一页挂在**控件旁边**的说明行（16 字那条线量的就是它们）。
    static var writingCaptions: [String] {
        [vocabularyHardReplace, customRulesPlaceholder]
    }

    /// 页面开头那一整句。5.0.2 起**一句都没有了**（用户 2026-09-23 拍板）：
    /// 那一页两个框各自带着栏名和一颗 ⓘ，开场白说的是同一件事，只是把控件往下推了一行。
    /// 这张表留着是因为那条"整句说明"的预算线本身还在（将来再有开场白，它自动受约束）。
    static var pageIntros: [String] { [] }

    /// 「专有词汇表」那一页的两颗 ⓘ（词汇表 / 自定义规则）
    static var writingInfos: [String] {
        [vocabularyInfo, customRulesInfo]
    }

    /// 「关于」页上那两颗 ⓘ（4.3.3 从「输入」页搬来：保存听写历史 / 设置备份）。
    /// 它们照旧按同一条 120 字预算量——换了页不换规矩。
    static var aboutInfos: [String] {
        [behaviourInfo, backupInfo]
    }

    // MARK: - 专有词汇表（自己的一页，从设置底部那排小字点开）

    /// 这一页的名字。**只写一处**：设置状态页那一行的栏名、子页顶栏的标题念的是同一串。
    ///
    /// 5.3.0 改回「写作偏好 / Writing」（用户 2026-09-29 拍板）：状态页那一行叫「写作偏好」，
    /// 点进去的页名必须一样；「专有词汇表」只留作页里第一个框的栏名。
    ///
    /// 5.0.2 从「写作偏好 / Writing preferences」改名（用户 2026-09-23 拍板）：
    /// 那一页里就是一张词表加一段规则，而「写作偏好」听着像一整套排版设置——
    /// 用户按名字去找"怎么让它别听错我的名字"时，不会点进一个叫"写作偏好"的地方。
    static var vocabularyPageTitle: String {
        tr("写作偏好", "Writing")
    }

    // writingPreferencesIntro（页面开头那句「人名、术语、写作习惯——识别与润色都会参考」）
    // 5.0.2 删掉：它说的和下面那颗 ⓘ 是同一件事，只是把两个框往下推了一行。

    static var vocabularyHardReplace: String {
        tr("也支持「错写=正写」硬替换", "Supports hard replacement, written as wrong=right")
    }

    /// 5.1.0 删掉了「阿里云那一档识别时不认它」那一句：那一档没有了。
    static var vocabularyInfo: String {
        tr("这些词作为热词直接送进 OpenAI 的云端识别，也参与 AI 润色纠错——专有名词准确率的第一杠杆。硬替换「杰文=捷文」零耗时，一个正写可挂多个错写「杰文|捷纹=捷文」。口水词内置。",
           "These terms go as hotwords to OpenAI cloud recognition, and are used by AI polish — the number one lever for proper-noun accuracy. Hard replacement such as \"Jevin=Jaywen\" rewrites every occurrence at zero latency, and one correct form can take several wrong spellings: \"Jevin|Javin=Jaywen\". Filler words are built in.")
    }

    // MARK: - 云端 AI

    /// 「自定义规则」那个框空着时里面的灰字。写两个**能照抄的**例子，而不是"请输入…"：
    /// 这个框最大的门槛从来不是不会打字，是不知道该往里写什么。
    static var customRulesPlaceholder: String {
        tr("例如：署名用 Gen；邮件偏正式", "For example: sign as Gen; formal in email")
    }

    // 服务商选择器那一套（「正在使用 ✓」providerInUse、「预览中，仍用 X」providerNotSetUp）
    // 5.1.0 删掉：只剩 OpenAI 一家，没有选择器，也就没有"看着的那一档还没生效"这回事。

    /// Key 验通之后，状态行末尾那半句（设置页）：**这一档一小时大概多少钱**。
    ///
    /// 为什么是"一小时"而不是"一句话"：来设置页的人已经在用了，他关心的是月底那张账单；
    /// 引导 ③ 那一处补的是"一句话多少钱"（那时候一小时对他还没有概念）。
    /// 单价的唯一出处是 LLMCatalog，两处算的是同一套数。
    static func connectedCost(provider: LLMProvider) -> String {
        tr("识别 + 润色\(LLMCatalog.hourlyCostNote(provider: provider))",
           "recognition + polish, \(LLMCatalog.hourlyCostNote(provider: provider))")
    }

    // 云端识别那三句（边说边上传 / 默认关 / 打开后多少钱）与「本机模型不需要 Key」那一句
    // 5.0.0 一起删掉：识别永远云端，那个开关没有了；而"录音会离开这台 Mac、按秒计费"
    // 这件事改由引导 ③ 与 关于 → 隐私 各说一次（PrivacyCopy）。

    // 「接入地址」那一栏（阿里云的 API Host，hostMalformed 那一句）5.1.0 随阿里云删掉。

    /// Key 那一行右端那颗 ⓘ——**整页只剩三颗之一**（4.3.2）。
    ///
    /// 存储与费用两句必须逐字引用 LLMCatalog（全 App 唯一出处）。费用那句 4.3.2 之前
    /// 是常驻在输入框下面的一行字：它一天要被同一个人读一百遍，而它说的事一个月也用不上
    /// 一次——所以收进这颗 ⓘ（用户 2026-09-22 嫌这一页冗余，这是最该收的一行）。
    ///
    /// **「新账号要先充值」那句删了**：余额不足时 429 那条错误话术会当面说，还带一个
    /// 「去充值」的链接（LLMCatalog.describeHTTPError）——在真的撞上之前先讲一遍，
    /// 属于"预支的焦虑"。
    /// **「开着云端识别就拿识别端点验」那句也删了**：验完的状态行写的是
    /// 「已连通 ✓ 云端·OpenAI · gpt-transcribe」，它自己就把这件事演示了一遍。
    ///
    /// 5.1.0 起只有 OpenAI 一档（阿里云那一档多出来的"API Host 留空即自动找"随之删掉）。
    static var keyInfo: String {
        // 「一小时大概多少钱」：5.0.0 起识别也要花钱，而这颗 ⓘ 是设置页上唯一
        // 能说这件事的地方。单价的唯一出处是 LLMCatalog
        let cost = tr("识别加润色\(LLMCatalog.hourlyCostNote(provider: .openai))，按说话时长算。",
                      "Recognition plus polish: \(LLMCatalog.hourlyCostNote(provider: .openai)) of speech.")
        // 5.0.2 从 关于 → 隐私 搬来的两个半句（那一段压到三句，而这两句讲的是**花钱**，
        // 这里本来就在说一小时多少钱——单价的唯一出处仍是 LLMCatalog）：
        //   • 按住说指令时的联网搜索没有开关、永远开；
        //   • OpenAI 官方接口一律 Fast 档。
        let search = tr("按住说指令会联网搜索（永远开）：", "Hold-to-command searches the web (always on): ")
            + LLMCatalog.webSearchPriceNote
        let fast = tr("OpenAI 官方接口走 Fast 档：", "The official OpenAI API runs in the Fast tier: ")
            + LLMCatalog.fastTierPriceNote
        return LLMCatalog.keyStorageNote + "\n" + LLMCatalog.billingNote + "\n" + cost
            + "\n" + search + "\n" + fast
    }

    // 「实时草稿」开关的栏名与 ⓘ（livePreviewLabel / livePreviewInfo）5.2.0 删掉：
    // 录音中的灰字草稿改成悬浮窗右端的字数计数（UX 方案 §3 C），这一页没有开关了。

    // 云端识别那颗 ⓘ（cloudRecognitionInfo，按家两份）5.0.0 删掉：没有那个开关了。
    // 两家的计费与留存口径现在只在 关于 → 隐私（PrivacyCopy）里说一次。


    /// 「自定义规则」那颗 ⓘ。**最后一句是数据流向，不是修辞**：这个框会跟着每一次润色
    /// （PolishService.polishPrompt）和每一条语音指令（AgentService.userContextHint）发出去。
    ///
    /// 4.1.1 起这里只有一个框：原先的「关于我」已经并进来了（AISetup.mergedRules），
    /// 所以例子要把两类话都带上——"我是谁"和"怎么写"本来就写在同一段话里最自然。
    static var customRulesInfo: String {
        tr("写给 AI 的长期偏好：署名用 Gen、邮件偏正式、英文术语保留原文、数字用阿拉伯数字。每次润色和每条语音指令都会带上它，轻点听写不润色时不发。",
           "Long-standing preferences for the AI: sign as Gen, keep email formal, leave English jargon untranslated, use Arabic numerals. It travels with every polish and every voice command, and goes nowhere when polish is off.")
    }

    // 「高级」那颗 ⓘ 5.0.0 删掉：那一段只为已经不存在的两档服务商渲染。

    // 联网搜索那颗 ⓘ 与「这家没有联网搜索」那一行 5.0.0 删掉：支持的服务商永远开，
    // 没有开关可解释；代价在 关于 → 隐私 里说一次。

    // 「优先处理」那颗 ⓘ（priorityInfo）与「上一次请求实际跑在：」（lastServiceTier）
    // 4.1.6 一起删了：那一段整个不存在了（用户 2026-09-21 拍板，OpenAI 官方接口恒走 Fast），
    // 而屏幕上没有那个开关之后，这两句话一句也没有落脚的地方。代价改在 关于 → 隐私 说一次
    //（PrivacyCopy.fastTier）；服务商实际给了哪一档照常进 Metrics 与诊断信息。

    /// 这一页**常驻**在屏幕上的说明行。5.1.0 起一条都没有了：原来那两条（「预览中，仍用 X」、
    /// 「这串不像接入地址」）随服务商选择器与阿里云的接入地址一起删掉。
    /// 这张表留着是因为"设置页说明合计"那条预算线还在（将来再加，它自动受约束）。
    static var cloudCaptions: [String] { [] }

    /// 设置正页的 ⓘ：只剩 API Key 那一颗（「实时草稿」那一颗 5.2.0 随开关删掉）。
    static var cloudInfos: [String] {
        [keyInfo]
    }

    // MARK: - 概览（权限横幅：缺了才出现，一行 + 一颗按钮）

    static var microphoneMissing: String {
        tr("麦克风还没授权，录不到声音", "Microphone is not granted: nothing is recorded")
    }

    static var accessibilityMissing: String {
        tr("辅助功能没授权：热键和输入都无效", "Accessibility is not granted: no hotkey, no typing")
    }

    static var overviewCaptions: [String] {
        [microphoneMissing, accessibilityMissing]
    }

    // MARK: - 边界状态（一行结论 + 一颗按钮，永远不写成一段话）

    // 「润色在菜单栏里关着」与两条「识别停在旧档」5.0.0 删掉：润色没有开关了，
    // 识别引擎跟着生效服务商走，这三种说不通的状态都不再可能出现。

    // launchAtLoginFailed（「系统没让改登录项」）5.3.0 删掉：引导最后那一屏的登录自启开关没有了，
    // ③ 那一行直接照实写「已开启 / 未开启」（OnboardingCopy.launchAtLogin），原因只进日志。

    /// 官方几档的地址被老版本改过：看不见的自定义地址是查不出来的故障
    static var endpointOverridden: String {
        tr("这一档的接口地址被改过：", "This provider's endpoint was overridden: ")
    }

    // 「这一档的地址改由导入设置配置」与模型下载 / 升级那六句 5.0.0 一起删掉：
    // 自定义端点那一档没有了，本机模型也没有了。

    static var boundaryLines: [String] {
        [endpointOverridden]
    }

    // MARK: - 预算表（单测按这几张表逐条量）

    /// 引导里**挂在控件下面**那几行也走同一条预算线（文字本身住在 OnboardingCopy 里）：
    /// 第一次打开 MicType 的人最没耐心读字，凭什么反而不受这 16 字的约束。
    /// 引导里那些整句的说明装不进 16 字，另算一条线（OnboardingCopy.paragraphs）。
    static var allCaptions: [String] {
        writingCaptions + cloudCaptions + overviewCaptions + OnboardingCopy.captions
    }

    static var allInfos: [String] {
        writingInfos + cloudInfos + aboutInfos
    }
}
