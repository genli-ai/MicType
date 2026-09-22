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

    // MARK: - 输入

    /// 快捷键那一行下面唯一那一行。Esc 取消这件事收进 ⓘ——它是用到的时候才要知道的
    static var hotkeyGestures: String {
        tr("轻点听写，按住说指令", "Tap to dictate, hold to command")
    }

    static var hotkeyInfo: String {
        tr("轻点开始、再轻点结束听写；按住说完松手执行语音指令。录音中按 Esc 取消。长录音已经转出前几段时，第一次 Esc 是收尾并输入，再按一次才彻底丢弃。",
           "Tap to start dictation and tap again to stop; hold, speak and release to run a voice command. Esc cancels while recording. Once a long take has already produced text, the first Esc finishes and inserts it — press it again to discard everything.")
    }

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
        tr("导出一个 JSON：词汇表、自定义规则、型号、识别引擎与语言、界面语言。导入是合并，别人给的文件可能把识别改成云端（会提示一次）。API Key 从不导出、也从不导入。",
           "Exports one JSON file: vocabulary, custom rules, model names, recognition engine and language, and the interface language. Import merges, and a file from someone else can switch recognition to a cloud engine (the summary says so). API keys are never exported or imported.")
    }

    /// 「只用本地」这一档下，自定义规则一个字都不会被发出去。框照样能填能存，
    /// 但这一刻它不生效——不说的话，用户会以为自己写的规则正在起作用。
    static var rulesNeedAI: String {
        tr("开启 AI 后生效", "Takes effect once AI is on")
    }

    /// 「输入」页在屏幕上摆着的说明（录音上限那一行由 DictationController 现算，一并计入预算）。
    /// 4.1.6 起多了「写作偏好」那一段的三行（词汇表两句二选一 + 自定义规则的灰字 + 这一条）。
    /// 4.3.3 砍到只剩四条：录音上限那一行连同它说明的那几个开关一起撤了，
    /// 「没有本机模型，草稿不出现」也跟着走（那个开关已经不在界面上）。
    static var inputCaptions: [String] {
        [hotkeyGestures,
         vocabularyArabicTip, vocabularyHardReplace, customRulesPlaceholder, rulesNeedAI]
    }

    /// 4.3.3：这一页只剩三颗 ⓘ（快捷键 / 词汇表 / 自定义规则）。
    static var inputInfos: [String] {
        [hotkeyInfo, vocabularyInfo, customRulesInfo]
    }

    /// 「关于」页上那两颗 ⓘ（4.3.3 从「输入」页搬来：保存听写历史 / 设置备份）。
    /// 它们照旧按同一条 120 字预算量——换了页不换规矩。
    static var aboutInfos: [String] {
        [behaviourInfo, backupInfo]
    }

    // MARK: - 本地识别

    /// 云端的语言表比这张选单短：它不认识的语言码，提示根本送不出去
    static var cloudTakesNoHint: String {
        tr("云端不收这个语言的提示", "The cloud engine takes no hint for this language")
    }

    /// 云端识别开着时，本机模型并没有变成多余的东西——不说的话用户会把它删掉
    static var localModelStillUsed: String {
        tr("本机模型仍做草稿与回落", "The on-device model still does drafts and fallback")
    }

    /// 阿语实测（2026-09-19）：热词把 CER 从 12.5% 压到 4.0%，换更大的模型反而更差
    static var vocabularyArabicTip: String {
        tr("阿语：填英文专名最有效", "Arabic: adding English product names helps most")
    }

    static var vocabularyHardReplace: String {
        tr("也支持「错写=正写」硬替换", "Supports hard replacement, written as wrong=right")
    }

    static var performanceCloudRoundTrip: String {
        tr("云端档：「识别」量的是往返", "Cloud engine: the ASR figure is a round trip")
    }

    /// 麦克风自检那段说明（设置页收进 ⓘ，引导页同样引用这一句）
    static var micCheckInfo: String {
        tr("测试会录 3 秒，只看音量：录到的声音当场丢弃，不识别、不保存。选定的麦克风在开始录音时没插上，这一次会自动退回系统默认，设置本身不改动。",
           "The test records for 3 seconds and only meters the level — the audio is discarded, never transcribed or saved. If the selected microphone is not connected when recording starts, MicType falls back to the system default for that session and leaves your choice untouched.")
    }

    static var languageInfo: String {
        tr("自动检测对中英文很准，默认就好。说小语种、或中英夹杂被判错时指定语言更稳，指定只影响识别。云端引擎读的是同一条设置：具体语言作为提示送过去，云端不认识的语言码一个提示都不会送。",
           "Automatic detection is reliable for Chinese and English, so the default is fine. Pick a language when you speak something else, or when mixed speech gets detected wrong; it only affects recognition. Cloud engines read the same setting: a specific language is sent as a hint, and a language the provider does not know is never sent at all.")
    }

    /// 识别模型那颗 ⓘ。
    ///
    /// **回落那一句不在这里**：「云端识别开着时本机模型还管草稿与回落」是云端识别那一档的事实，
    /// 写在做那个选择的地方（cloudRecognitionInfo）。控件旁边那行 localModelStillUsed 是它的一句话版本。
    static var modelInfo: String {
        tr("Qwen3-ASR：约 30 种语言 + 22 种中文方言，自动检测语言，识别完全在本机进行，模型来自 HuggingFace。1.7B 更准但不太吃词汇表热词，夹英文专名的口述建议用推荐档。",
           "Qwen3-ASR: about 30 languages plus 22 Chinese dialects, automatic language detection, fully on-device, downloaded from HuggingFace. The 1.7B model is more accurate but responds less to vocabulary hotwords, so speech with embedded English names does better on the recommended one.")
    }

    static var vocabularyInfo: String {
        tr("这些词作为热词直接送进本机识别模型与 OpenAI 云端识别，也参与 AI 润色纠错——专有名词准确率的第一杠杆。阿里云那一档识别时不认它，由润色纠正。硬替换「杰文=捷文」零耗时，一个正写可挂多个错写「杰文|捷纹=捷文」。口水词内置。",
           "These terms go as hotwords to the on-device model and to OpenAI cloud recognition, and are used by AI polish — the number one lever for proper-noun accuracy. Alibaba Cloud recognition ignores them, so polish fixes those names afterwards. Hard replacement such as \"Jevin=Jaywen\" rewrites every occurrence at zero latency, and one correct form can take several wrong spellings: \"Jevin|Javin=Jaywen\". Filler words are built in.")
    }

    static var performanceInfo: String {
        tr("识别与插入都在本机完成；「模型」那一段是到大模型接口的网络往返，括号里是它实际统计了几轮。只统计数字，不保存任何听写内容。",
           "Recognition and insertion run on this Mac; the Model figure is the network round trip to your model endpoint, and the number in brackets is how many rounds went through it. Only timings are stored — never any transcribed text.")
    }

    /// 4.1.6 起词汇表那两句不在这一页（控件搬去了「输入 → 写作偏好」）
    static var recognitionCaptions: [String] {
        [cloudTakesNoHint, localModelStillUsed, performanceCloudRoundTrip]
    }

    static var recognitionInfos: [String] {
        [micCheckInfo, languageInfo, modelInfo, performanceInfo]
    }

    // MARK: - 云端 AI

    /// 其他兼容服务 / 本机模型没有内置型号：指路「高级」，而不是摆一个点了没反应的下拉
    static var modelNameInAdvanced: String {
        tr("型号名在下面的「高级」里填", "Type the model id under Advanced below")
    }

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

    /// 选择器上看着的这一档还没配 Key：它现在只是**预览**，生效的仍然是上一档。
    ///
    /// 为什么要把生效那家的名字念出来：预览的这一刻，「正在使用 ✓」恰好不在屏幕上
    ///（它只长在生效那一段旁边），而"现在真正在用哪一家"正是这一版要解决的问题——
    /// 最需要这句话的时刻反而没有，就等于没解决。引导页同一状态本来就这么写
    ///（OnboardingCopy.providerNotAdoptedYet）。
    static func providerNotSetUp(current: String) -> String {
        tr("预览中，仍用 " + current, "Previewing — still using " + current)
    }

    /// 云端识别开关下面那一行的中段。**代价写在开关旁边**：型号与单价由渲染处补在两头
    /// （单价的唯一出处是 LLMCatalog.cloudASRPriceNote——两家差着近八倍，不许藏进 ⓘ）。
    ///
    /// 4.1.7 起写「边说边上传」而不是「音频上传」：这一档已经不是录完再传了——
    /// 按下热键就连上，你说话的同时音频就在往服务商去（这样松手才能立刻出结果）。
    /// 写成"上传"会让人以为按 Esc 就什么都没发出去过，那是假的。
    static var cloudRecognitionCost: String {
        tr("边说边上传", "Audio streams up as you speak")
    }

    static var cloudRecognitionOff: String {
        tr("默认关：录音不出这台 Mac", "Off by default: no audio leaves this Mac")
    }

    /// 关着的时候也要看得到价钱：决定要不要打开的那一刻，价钱必须已经在眼前——
    /// 两家差着近八倍，而拨开开关本身就会真连一次、花掉一两秒的钱。渲染处把它接在
    /// 「默认关」那一句后面；单价仍然只有 LLMCatalog.cloudASRPriceNote 一个出处。
    static func cloudRecognitionPriceWhenOn(_ price: String) -> String {
        tr("打开后\(price)", "\(price) when on")
    }

    /// 本机模型那一档没有 Key 不是"还没配好"，是这一档的正常状态
    static var localModelNeedsNoKey: String {
        tr("本机模型不需要 Key，也不花钱", "On-device models need no key and cost nothing")
    }

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
        let base = LLMCatalog.keyStorageNote + "\n" + LLMCatalog.billingNote
        guard hostField else { return base }
        return base + "\n" + tr("API Host 留空即自动选择；要固定就填百炼控制台的接入地址。",
                                "Leave API Host empty to choose automatically, or paste the host from the Model Studio console to pin it.")
    }

    /// 云端识别那颗 ⓘ：上传、计费、留存、回落——每家各一份。
    ///
    /// 为什么不放进 PrivacyCopy：那几句讲的是**默认状态**（关于页与引导页），而云端识别是用户
    /// 另点出来的一档，它的代价只该出现在做这个选择的地方。同一个事实仍然只写一处。
    ///
    /// 两份都**必须点名钱**：OpenAI 那一档约每小时 1 美元，是阿里云那一档的近八倍——
    /// 用户按这个开关之前有权知道自己选的是哪一种。
    /// OpenAI 的数据政策照它官方文档写（2026-09-21 查证，developers.openai.com 的
    /// 「Your data」页）：API 数据默认不用于训练，滥用监控日志最多保留 30 天。
    /// **不许凭印象写**——查不到就只说"以服务商的政策为准"。
    ///
    /// 阿里云那一份 4.3.2 多了一句"识别时不认词汇表"，那是 2026-09-22 拿真 Key 测出来的：
    /// `qwen3-asr-flash-realtime` 对 vocabulary / hotwords / phrase_list / context / prompt /
    /// corpus.text / corpus_text **全都无效或直接丢弃**——这一档在识别环节没有任何通道能
    /// 把词汇表送进去。专名是靠润色（润色 prompt 带着词汇表，实测能把 MixType→MicType、
    /// Quin 三点零→Qwen 3.0 纠回来）和「错写=正写」硬替换补的。用户按这个开关之前有权知道。
    ///
    /// 为了塞下这句话（120 字硬预算），删掉了阿里云那一份里的两句：
    ///   • 「第一次用之前要在百炼控制台把这个模型开通一次」——没开通的表现是拨开开关当场
    ///     报 403，而那句错误话术本来就指着「模型广场」（AlibabaASRClient.failure）；
    ///   • 「出错时自动改用本机模型再识别一遍」——真回落时悬浮窗会当面说
    ///     （CloudFallbackDecision.fallbackNote），不必预先讲一遍。
    static func cloudRecognitionInfo(provider: CloudASRProvider) -> String {
        switch provider {
        case .alibaba:
            return tr("每段录音在你说话的同时就传给阿里云，按音频秒数计费（约每小时 0.13 美元）。阿里云声明不拿这些数据训练模型，但会保存调用数据，没有公布保留期。这一档识别时不认词汇表，专名由润色按词汇表纠正；要识别时就认，用 OpenAI 那一档。",
                      "Every recording streams to Alibaba Cloud while you speak, billed by the second (about $0.13 per hour) directly by the provider. Alibaba Cloud states this data is not used to train models, but it does store data generated by API calls, with no published retention period. This engine ignores your vocabulary while recognizing; proper nouns are fixed afterwards by polish, which does use it. Pick OpenAI to have the vocabulary honoured during recognition itself.")
        case .openai:
            return tr("每段录音在你说话的同时就传给 OpenAI，按分钟计费（约每小时 1 美元，是阿里云那一档的数倍）。它认你的词汇表，专名更准。OpenAI 声明 API 数据默认不用于训练，滥用监控日志最多留 30 天。出错时自动改用本机模型再识别一遍。",
                      "Every recording streams to OpenAI while you speak, billed per minute (about $1 per hour, several times the Alibaba Cloud option) directly by the provider. It honours your vocabulary, so proper nouns come out right. OpenAI states API data is not used to train its models by default, and abuse-monitoring logs are kept for up to 30 days. If the cloud call fails, MicType re-runs recognition on this Mac.")
        }
    }

    /// 「自定义规则」那颗 ⓘ。**最后一句是数据流向，不是修辞**：这个框会跟着每一次润色
    /// （PolishService.polishPrompt）和每一条语音指令（AgentService.userContextHint）发出去。
    ///
    /// 4.1.1 起这里只有一个框：原先的「关于我」已经并进来了（AISetup.mergedRules），
    /// 所以例子要把两类话都带上——"我是谁"和"怎么写"本来就写在同一段话里最自然。
    static var customRulesInfo: String {
        tr("写给 AI 的长期偏好：署名用 Gen、邮件偏正式、英文术语保留原文、数字用阿拉伯数字。每次润色和每条语音指令都会带上它，轻点听写不润色时不发。",
           "Long-standing preferences for the AI: sign as Gen, keep email formal, leave English jargon untranslated, use Arabic numerals. It travels with every polish and every voice command, and goes nowhere when polish is off.")
    }

    /// 「高级」那颗 ⓘ。4.1.4 起这一段**只为没有内置型号清单的那两档渲染**
    /// （其他 OpenAI 兼容服务 / 本机模型），所以这句话只说那两档的事——
    /// 三家官方档的型号由下拉决定、Key 在粘的时候就验过了，整段都不出现。
    static var advancedInfo: String {
        tr("这一档没有内置清单：型号名照服务商文档填，「刷新」问端点它现在有哪些，「测试模型」拿它真发一次最短请求、报往返毫秒数，不动任何设置。",
           "This provider has no built-in list: type the model id from its docs, hit Refresh to ask the endpoint what it serves, and Test the model sends one real minimal request and reports the round trip; it changes no settings.")
    }

    /// 联网搜索那颗 ⓘ：**只说这个开关管到哪儿**。单价写在开关旁边（价格是代价不是解释，
    /// 出处只有 LLMCatalog.webSearchPriceNote 一个），不搬进来。
    static var webSearchInfo: String {
        tr("只有按住说指令时才可能联网；轻点听写的润色永远不联网，也永远不花这笔钱。搜没搜过会写在悬浮窗和历史里。",
           "Only hold-to-command can search the web; the polish behind tap-to-dictate never does, and never costs you this. Whether a call searched is shown in the overlay and in your history.")
    }

    /// 联网搜索这一档压根没有：**连开关都不摆**，只留这一行说明
    static var webSearchUnsupported: String {
        tr("此服务商不支持联网搜索", "Web search is not available on this provider")
    }

    // 「优先处理」那颗 ⓘ（priorityInfo）与「上一次请求实际跑在：」（lastServiceTier）
    // 4.1.6 一起删了：那一段整个不存在了（用户 2026-09-21 拍板，OpenAI 官方接口恒走 Fast），
    // 而屏幕上没有那个开关之后，这两句话一句也没有落脚的地方。代价改在 关于 → 隐私 说一次
    //（PrivacyCopy.fastTier）；服务商实际给了哪一档照常进 Metrics 与诊断信息。

    /// 这一页**常驻**在屏幕上的说明行。4.3.2 砍到只剩"带着钱或隐私"的那几条
    ///（用户 2026-09-22：这一页太冗余）——删掉的是使用方式下那句、模型下那句、
    /// Key 下那行费用、接入地址下那两句。剩下的几条要么是价钱，要么只在出事时才出现。
    static var cloudCaptions: [String] {
        [providerNotSetUp(current: "OpenAI"), modelNameInAdvanced,
         localModelNeedsNoKey, hostMalformed,
         cloudRecognitionCost, cloudRecognitionOff,
         webSearchUnsupported]
    }

    /// 4.3.2 起整页只剩三颗 ⓘ：API Key、识别也用云端（按家两份）、联网搜索。
    /// advancedInfo 只在自定义端点 / 本机模型那两档的「高级」里出现，也算这一页头上。
    static var cloudInfos: [String] {
        [keyInfo(hostField: false), keyInfo(hostField: true),
         cloudRecognitionInfo(provider: .alibaba), cloudRecognitionInfo(provider: .openai),
         webSearchInfo, advancedInfo]
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

    static var polishOffInMenuBar: String {
        tr("润色在菜单栏里关着，轻点只出识别原文。",
           "Polish is switched off in the menu bar, so tapping gives the raw transcript.")
    }

    /// 识别停在 OpenAI、服务商却换走了：那个开关只在 OpenAI 档渲染，界面上没有关掉它的控件。
    /// 4.2.2 之前这一条说的是"4.0.0 的遗留档"——现在 OpenAI 云端识别是一档正常配置，
    /// 再那么写就会在用户刚把开关打开的那一秒当面劝他关掉。
    static var strandedOpenAIRecognition: String {
        tr("识别还走着 OpenAI（按分钟计费），服务商却不是它。",
           "Recognition still goes to OpenAI (billed per minute) although your provider is not OpenAI.")
    }

    /// 识别停在阿里云、服务商却换走了：那个开关只在阿里云档渲染，于是界面上没有关掉它的控件
    static var strandedAlibabaRecognition: String {
        tr("识别还走着阿里云（按秒计费），服务商却不是它。",
           "Recognition still goes to Alibaba Cloud (billed per second) although your provider is not Alibaba Cloud.")
    }

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

    static func endpointConfiguredByImport(provider: String) -> String {
        tr("「\(provider)」的地址改由「导入设置…」配置，现有配置照常工作。",
           "The endpoint for \(provider) is configured through Import Settings now; your current setup keeps working.")
    }

    /// 模型未下载 / 已就绪：识别页那一行状态
    static var modelReady: String { tr("模型已就绪", "Model ready") }
    static var modelNotDownloaded: String { tr("模型未下载", "Model not downloaded") }

    /// 目录里已经不列这一档了（换代下架），但用户正在用它
    static var modelNoLongerListed: String {
        tr("当前模型（目录里已不再列出）", "Current model (no longer listed)")
    }

    /// 升级横幅那三句结论。都只说"现在是什么情况"，动作写在按钮上
    static var modelUpgradeAvailable: String {
        tr("有更合适的识别模型：", "A better speech model is available: ")
    }

    static var modelHasNewRevision: String {
        tr("当前识别模型有新修订，重下后会校验再启用。",
           "The current speech model has a newer revision; the re-download is verified before use.")
    }

    static func modelNeedsAppUpdate(version: String) -> String {
        tr("这个新模型要求 MicType \(version) 或更高版本。",
           "That new model needs MicType \(version) or newer.")
    }

    static var boundaryLines: [String] {
        [polishOffInMenuBar,
         strandedOpenAIRecognition, strandedAlibabaRecognition, launchAtLoginFailed,
         endpointOverridden,
         endpointConfiguredByImport(provider: "Ollama"),
         modelReady, modelNotDownloaded, modelNoLongerListed,
         modelUpgradeAvailable, modelHasNewRevision, modelNeedsAppUpdate(version: "4.1.0")]
    }

    // MARK: - 预算表（单测按这几张表逐条量）

    /// 引导里**挂在控件下面**那几行也走同一条预算线（文字本身住在 OnboardingCopy 里）：
    /// 第一次打开 MicType 的人最没耐心读字，凭什么反而不受这 16 字的约束。
    /// 引导里那些整句的说明装不进 16 字，另算一条线（OnboardingCopy.paragraphs）。
    static var allCaptions: [String] {
        inputCaptions + recognitionCaptions + cloudCaptions + overviewCaptions
            + OnboardingCopy.captions
    }

    static var allInfos: [String] {
        inputInfos + recognitionInfos + cloudInfos + aboutInfos
    }
}
