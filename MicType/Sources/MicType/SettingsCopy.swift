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
    // 开机自启在引导 ⑤ 注册（要关去系统设置的登录项）。词汇表与自定义规则搬进「写作偏好」。

    /// 「保存听写历史」那一行的 ⓘ（4.3.3 起它和那个开关一起住在 关于 → 隐私）。
    ///
    /// 「存在哪儿、最多几条、不上传」那一句不在这里写：它是一句隐私陈述，出处只有一个
    /// （HistoryStore.storageNote，就摆在这个开关上面那几行）。4.1.0 之前这里自己写了一版
    /// （「history.json、200 条」）而关于页写的是另一版（「Application Support 目录、明文」），
    /// 条数一改就有两个答案。
    static var behaviourInfo: String {
        tr("关掉即停止记录，已有的记录不动：清空在菜单栏「最近记录 → 清空记录」，逐条删在历史窗口（⌘Y）。",
           "Turning this off stops recording immediately and leaves existing entries alone: clear them from the menu bar (Recent Transcripts → Clear History), or delete them one by one in the History window (⌘Y).")
    }

    static var backupInfo: String {
        tr("导出一个 JSON：词汇表、自定义规则、服务商与接入地址、界面语言。导入是合并，别人给的文件可能把服务商或接入地址换掉（会提示一次）。API Key 从不导出、也从不导入。",
           "Exports one JSON file: vocabulary, custom rules, provider and endpoint, and the interface language. Import merges, and a file from someone else can switch your provider or endpoint (the summary says so). API keys are never exported or imported.")
    }

    // rulesNeedAI 5.0.0 删掉：没有「只用本地」那一档了，自定义规则永远会被发出去。

    /// 「写作偏好」那一页挂在**控件旁边**的说明行（16 字那条线量的就是它们）。
    /// 页面开头那一整句不在这里：它不是挂在某个控件旁边的注脚，而是这一页的开场白，
    /// 走 pageIntros 那条更宽的线（见那里）。
    static var writingCaptions: [String] {
        [vocabularyHardReplace, customRulesPlaceholder]
    }

    /// 页面开头那一整句（目前只有「写作偏好」有）。**另算一条线**：
    /// 它回答的是"这一页是干什么的"，装不进 16 字，而硬压成 16 字的结果是一句谁也看不懂的口号。
    /// 量它的是与引导段落同一条线（中文 ≤ 60 字），见 SettingsCopyBudgetTests。
    static var pageIntros: [String] { [writingPreferencesIntro] }

    /// 「写作偏好」那一页的两颗 ⓘ（词汇表 / 自定义规则）
    static var writingInfos: [String] {
        [vocabularyInfo, customRulesInfo]
    }

    /// 「关于」页上那两颗 ⓘ（4.3.3 从「输入」页搬来：保存听写历史 / 设置备份）。
    /// 它们照旧按同一条 120 字预算量——换了页不换规矩。
    static var aboutInfos: [String] {
        [behaviourInfo, backupInfo]
    }

    // MARK: - 写作偏好（自己的一页，从设置底部那排小字点开）

    /// 这一页开头唯一一句解释：回答"这两个框是干什么的"。
    /// **点名识别与润色都会参考**——词汇表在 OpenAI 那一档是识别时的热词，
    /// 在阿里云那一档由润色纠正，两条路都用得上，写成"润色时参考"就少说了一半。
    static var writingPreferencesIntro: String {
        tr("人名、术语、写作习惯——识别与润色都会参考",
           "Names, jargon, writing habits - used by both recognition and polish")
    }

    static var vocabularyHardReplace: String {
        tr("也支持「错写=正写」硬替换", "Supports hard replacement, written as wrong=right")
    }

    static var vocabularyInfo: String {
        tr("这些词作为热词直接送进 OpenAI 的云端识别，也参与 AI 润色纠错——专有名词准确率的第一杠杆。阿里云那一档识别时不认它，由润色纠正。硬替换「杰文=捷文」零耗时，一个正写可挂多个错写「杰文|捷纹=捷文」。口水词内置。",
           "These terms go as hotwords to OpenAI cloud recognition, and are used by AI polish — the number one lever for proper-noun accuracy. Alibaba Cloud recognition ignores them, so polish fixes those names afterwards. Hard replacement such as \"Jevin=Jaywen\" rewrites every occurrence at zero latency, and one correct form can take several wrong spellings: \"Jevin|Javin=Jaywen\". Filler words are built in.")
    }

    // MARK: - 云端 AI

    /// 「自定义规则」那个框空着时里面的灰字。写两个**能照抄的**例子，而不是"请输入…"：
    /// 这个框最大的门槛从来不是不会打字，是不知道该往里写什么。
    static var customRulesPlaceholder: String {
        tr("例如：署名用 Gen；邮件偏正式", "For example: sign as Gen; formal in email")
    }

    /// 服务商选择器上「正在使用」的那一档。**不是 Caption**（它是选择器旁边的一枚小标签），
    /// 所以不进那张 16 字的表，但仍然只写这一处。
    ///
    /// 为什么非有不可（用户 2026-09-20 的实测反馈）：三档并排、每一档都点得动，屏幕上却
    /// 没有任何地方写着"现在真正在用的是哪一家"——于是人人都挨个点一遍，最后停在哪档就是哪档。
    static var providerInUse: String {
        tr("正在使用 ✓", "In use ✓")
    }

    /// Key 验通之后，状态行末尾那半句（设置页）：**这一档一小时大概多少钱**。
    ///
    /// 为什么是"一小时"而不是"一句话"：来设置页的人已经在用了，他关心的是月底那张账单；
    /// 引导 ③ 那一处补的是"一句话多少钱"（那时候一小时对他还没有概念）。
    /// 单价的唯一出处是 LLMCatalog，两处算的是同一套数。
    static func connectedCost(provider: LLMProvider) -> String {
        tr("识别 + 润色\(LLMCatalog.hourlyCostNote(provider: provider))",
           "recognition + polish, \(LLMCatalog.hourlyCostNote(provider: provider))")
    }

    /// 选择器上看着的这一档还没配 Key：它现在只是**预览**，生效的仍然是上一档。
    ///
    /// 为什么要把生效那家的名字念出来：预览的这一刻，「正在使用 ✓」恰好不在屏幕上
    ///（它只长在生效那一段旁边），而"现在真正在用哪一家"正是这一版要解决的问题——
    /// 最需要这句话的时刻反而没有，就等于没解决。引导页同一状态本来就这么写
    ///（OnboardingCopy.providerNotAdoptedYet）。
    static func providerNotSetUp(current: String) -> String {
        tr("预览中，仍用 " + current, "Previewing — still using " + current)
    }

    // 云端识别那三句（边说边上传 / 默认关 / 打开后多少钱）与「本机模型不需要 Key」那一句
    // 5.0.0 一起删掉：识别永远云端，那个开关没有了；而"录音会离开这台 Mac、按秒计费"
    // 这件事改由引导 ③ 与 关于 → 隐私 各说一次（PrivacyCopy）。

    // MARK: 接入地址（只有阿里云有，见 QwenHostField）

    /// 填的东西拼不出主机名。**不删、不清空**，只说它现在不算数
    static var hostMalformed: String {
        tr("这串不像接入地址，暂不使用", "Not a hostname, so it is ignored for now")
    }

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
    /// 「已连通 ✓ 阿里云 · qwen3-asr-flash」，它自己就把这件事演示了一遍。
    ///
    /// - hostField: 这一档下面跟着 API Host 那一行（只有阿里云）。那一栏没有自己的 ⓘ，
    ///   "去哪儿找这一串"就挂在这里——它和 Key 本来就印在百炼控制台的同一页上。
    static func keyInfo(hostField: Bool) -> String {
        // 「这一家一小时大概多少钱」：5.0.0 起识别也要花钱，而这颗 ⓘ 是设置页上唯一
        // 能说这件事的地方。单价的唯一出处是 LLMCatalog（引导 ③ 的卡片念的是同一个数）
        let provider: LLMProvider = hostField ? .qwen : .openai
        let cost = tr("识别加润色\(LLMCatalog.hourlyCostNote(provider: provider))，按说话时长算。",
                      "Recognition plus polish: \(LLMCatalog.hourlyCostNote(provider: provider)) of speech.")
        let base = LLMCatalog.keyStorageNote + "\n" + LLMCatalog.billingNote + "\n" + cost
        guard hostField else { return base }
        return base + "\n" + tr("API Host 留空即自动找，填了就只用那一台。",
                                "Leave API Host empty to find one automatically, or paste one to pin it.")
    }

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

    /// 这一页**常驻**在屏幕上的说明行。5.0.0 只剩两条，而且都只在出事时才出现。
    static var cloudCaptions: [String] {
        [providerNotSetUp(current: "OpenAI"), hostMalformed]
    }

    /// 5.0.0 起整页只剩一颗 ⓘ：API Key（阿里云那一档多一句"接入地址在哪儿找"）。
    static var cloudInfos: [String] {
        [keyInfo(hostField: false), keyInfo(hostField: true)]
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

    /// 登录项没改成：受管的 Mac 上它可能被 MDM 挡住，开关自己弹回去而屏幕上一个字都没有，
    /// 用户只会觉得这个开关坏了。原因（系统给的那句话）记进日志，界面上只留结论与去处。
    static var launchAtLoginFailed: String {
        tr("系统没让改登录项，可能被管理策略挡住。",
           "The system refused to change the login item, possibly blocked by a policy.")
    }

    /// 官方几档的地址被老版本改过：看不见的自定义地址是查不出来的故障
    static var endpointOverridden: String {
        tr("这一档的接口地址被改过：", "This provider's endpoint was overridden: ")
    }

    // 「这一档的地址改由导入设置配置」与模型下载 / 升级那六句 5.0.0 一起删掉：
    // 自定义端点那一档没有了，本机模型也没有了。

    static var boundaryLines: [String] {
        [launchAtLoginFailed, endpointOverridden]
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
