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

    // MARK: - 输入

    /// 快捷键选择器下面唯一那一行。Esc 取消这件事收进 ⓘ——它是用到的时候才要知道的
    static var hotkeyGestures: String {
        tr("轻点听写，按住说指令", "Tap to dictate, hold to command")
    }

    /// 老设置里存着的左侧修饰键（选择器上已经不摆了）。警告色，但仍然只有一行
    static var leftSideModifier: String {
        tr("左侧键天天参与组合键，误触多", "Left-side modifiers mistrigger more often")
    }

    /// 静音自动停止关着时才说：开着的时候步进器已经把行为说全了
    static var autoStopOff: String {
        tr("默认关：什么时候说完你定", "Off by default: you decide when you are done")
    }

    /// 只用云端、从没下过本机模型的人打开实时草稿开关什么也不会发生——当面说，别让他录一遍才发现
    static var draftNeedsLocalModel: String {
        tr("没有本机模型，草稿不出现", "No on-device model, so no draft appears")
    }

    static var draftOverlayOnly: String {
        tr("草稿只出现在悬浮窗里", "The draft only shows in the overlay")
    }

    static var hotkeyInfo: String {
        tr("轻点开始、再轻点结束听写；按住说完松手执行语音指令。录音中按 Esc 取消。长录音已经转出前几段时，第一次 Esc 是收尾并输入，再按一次才彻底丢弃。",
           "Tap to start dictation and tap again to stop; hold, speak and release to run a voice command. Esc cancels while recording. Once a long take has already produced text, the first Esc finishes and inserts it — press it again to discard everything.")
    }

    static var overlayInfo: String {
        tr("多屏时悬浮窗永远出现在鼠标所在那块屏，这里只决定它落在这块屏的哪个位置。录音中点胶囊右端那颗小按钮等同于按 Esc，而且不抢输入焦点。",
           "On multiple displays the overlay always appears on the screen holding the pointer; this only picks where it sits there. While recording, the small button at the right end of the capsule does exactly what pressing Esc does, without taking focus away from the app you are typing into.")
    }

    /// 录音那颗 ⓘ：自动收尾的语义 + 录音上限那一整句（数字全部来自常量，见 recordingLimitCopy）
    static var recordingInfo: String {
        tr("自动结束＝正常收尾这一段，不是丢弃；草稿只在悬浮窗里，不落到光标处。\n",
           "Auto-stop finishes the take normally — it is still transcribed and inserted, nothing is discarded. The live draft stays in the floating window and never reaches your cursor.\n")
            + DictationController.recordingLimitCopy
    }

    static var behaviourInfo: String {
        tr("听写历史只存在本机 history.json 里，最多 200 条，从不上传。关掉即停止记录；已有的记录可在菜单栏「最近记录 → 清空记录」清空，或在历史窗口（⌘Y）里逐条删。",
           "Transcripts are kept on this Mac in history.json (up to 200) and are never uploaded. Turning this off stops recording immediately; existing entries are left alone — clear them from the menu bar (Recent Transcripts → Clear History) or delete them one by one in the History window (⌘Y).")
    }

    static var backupInfo: String {
        tr("导出一个 JSON：词汇表、关于我、自定义规则、型号、识别引擎与语言、热键与界面语言。导入是合并，别人给的文件可能把识别改成云端（会提示一次）。API Key 从不导出、也从不导入。",
           "Exports one JSON file: vocabulary, about-me, custom rules, model names, recognition engine and language, hotkey and interface language. Import merges, and a file from someone else can switch recognition to a cloud engine (the summary says so). API keys are never exported or imported.")
    }

    /// 「输入」页在屏幕上摆着的说明（录音上限那一行由 DictationController 现算，一并计入预算）
    static var inputCaptions: [String] {
        [hotkeyGestures, leftSideModifier, autoStopOff, draftNeedsLocalModel, draftOverlayOnly,
         DictationController.recordingLimitShort]
    }

    static var inputInfos: [String] {
        [hotkeyInfo, overlayInfo, recordingInfo, behaviourInfo, backupInfo]
    }

    // MARK: - 本地识别

    static var languageAutoIsFine: String {
        tr("自动检测对中英文很准", "Automatic detection is reliable for Chinese and English")
    }

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
        tr("云端档：「识别」量的是往返", "Cloud engine: that figure is a round trip")
    }

    /// 麦克风自检那段说明（设置页收进 ⓘ，引导页同样引用这一句）
    static var micCheckInfo: String {
        tr("测试会录 3 秒，只看音量：录到的声音当场丢弃，不识别、不保存。选定的麦克风在开始录音时没插上，这一次会自动退回系统默认，设置本身不改动。",
           "The test records for 3 seconds and only meters the level — the audio is discarded, never transcribed or saved. If the selected microphone is not connected when recording starts, MicType falls back to the system default for that session and leaves your choice untouched.")
    }

    static var languageInfo: String {
        tr("说小语种、或中英夹杂被判错时指定语言更稳，指定只影响识别。云端引擎读的是同一条设置：具体语言作为提示送过去，云端不认识的语言码一个提示都不会送。",
           "Pick a language when you speak something else, or when mixed speech gets detected wrong; it only affects recognition. Cloud engines read the same setting: a specific language is sent as a hint, and a language the provider does not know is never sent at all.")
    }

    static var modelInfo: String {
        tr("Qwen3-ASR：约 30 种语言 + 22 种中文方言，自动检测语言，识别完全在本机进行，模型来自 HuggingFace。云端识别开着时，本机模型仍然负责实时草稿和云端出错时的回落。",
           "Qwen3-ASR: about 30 languages plus 22 Chinese dialects, automatic language detection, fully on-device, downloaded from HuggingFace. With cloud recognition on, the on-device model still produces the live draft and catches the take if the cloud call fails.")
    }

    static var vocabularyInfo: String {
        tr("这些词作为热词直接送进识别模型，也参与 AI 润色纠错——专有名词准确率的第一杠杆。硬替换「杰文=捷文」零耗时，一个正写可挂多个错写「杰文|捷纹=捷文」。云端引擎吃同一张表。口水词内置。",
           "These terms go to the speech model as hotwords and are used by AI polish — the number one lever for proper-noun accuracy. Hard replacement such as \"Jevin=Jaywen\" rewrites every occurrence at zero latency, and one correct form can take several wrong spellings: \"Jevin|Javin=Jaywen\". Cloud engines use the same list. Filler words are built in.")
    }

    static var performanceInfo: String {
        tr("识别与插入都在本机完成；「模型」那一段是到大模型接口的网络往返，括号里是它实际统计了几轮。只统计数字，不保存任何听写内容。",
           "Recognition and insertion run on this Mac; the Model figure is the network round trip to your model endpoint, and the number in brackets is how many rounds went through it. Only timings are stored — never any transcribed text.")
    }

    static var recognitionCaptions: [String] {
        [languageAutoIsFine, cloudTakesNoHint, localModelStillUsed,
         vocabularyArabicTip, vocabularyHardReplace, performanceCloudRoundTrip]
    }

    static var recognitionInfos: [String] {
        [micCheckInfo, languageInfo, modelInfo, vocabularyInfo, performanceInfo]
    }

    // MARK: - 云端 AI

    static var usageLocalOnly: String {
        tr("不联网、不花钱、不填 Key", "No network, no cost, no key to fill in")
    }

    static var usageWithAI: String {
        tr("本机识别，再交服务商润色", "Recognized on this Mac, then polished by your provider")
    }

    /// 其他兼容服务 / 本机模型没有内置型号：指路「高级」，而不是摆一个点了没反应的下拉
    static var modelNameInAdvanced: String {
        tr("型号名在下面的「高级」里填", "Name the model under Advanced below")
    }

    static var personalBoxesShared: String {
        tr("润色和指令都会读这两个框", "Both boxes are read by polish and by commands")
    }

    static var splitModelsRationale: String {
        tr("润色求快求省，指令求质量", "Polish wants speed and cost; commands want quality")
    }

    /// 云端识别开关下面那一行。**代价写在开关旁边**，具体单价在 ⓘ 里（同一个事实只写一处）
    static var cloudRecognitionCost: String {
        tr("音频上传 · 按秒计费", "Audio is uploaded, billed per second")
    }

    static var cloudRecognitionOff: String {
        tr("默认关：录音不出这台 Mac", "Off by default: no audio leaves this Mac")
    }

    /// 本机模型那一档没有 Key 不是"还没配好"，是这一档的正常状态
    static var localModelNeedsNoKey: String {
        tr("本机模型不需要 Key，也不花钱", "On-device models need no key and cost nothing")
    }

    /// 阿里云接入地址那个**可选**输入框：空着才是常态
    static var hostAutoDetected: String {
        tr("留空即可，MicType 自己试", "Leave it empty: MicType finds the endpoint itself")
    }

    static var hostFilledManually: String {
        tr("填了地址就只用它，不再试", "With a host filled in, MicType never probes")
    }

    static var usageInfo: String {
        tr("「只用本地」：识别和输入全在这台 Mac 上，不联网、不花钱，也不需要填 Key；按住说指令需要 AI，那一档没有。\n「本地 + AI」：轻点听写照旧在本机识别，文字再交给你选的服务商润色，按住说指令也走这家。",
           "Local only: recognition and typing all happen on this Mac — no network, no cost, no key. Hold-to-command needs AI, so it is not available there.\nLocal + AI: tapping still recognizes on this Mac and the text is then polished by the provider you pick; hold-to-command uses the same one.")
    }

    static var providerInfo: String {
        tr("三家官方档位的接口地址都是内置的，换一家只要贴那一家的 Key；每档各有一条钥匙串条目，换回来不用重贴。\n「其他 OpenAI 兼容服务」与「本机模型」改由「导入设置…」配置，已经在用的一切照旧。",
           "The endpoints of the three official providers are built in, so switching means pasting that provider's key. Each has its own Keychain entry, so switching back needs no re-paste.\nOther OpenAI-compatible services and on-device models are configured through Import Settings now; an existing setup keeps working.")
    }

    /// Key 那颗 ⓘ。存储与费用两句必须逐字引用 LLMCatalog（全 App 唯一出处）。
    /// - cloudASRProbe: 这把 Key 走的是识别端点而不是润色那条链路（开着云端识别的阿里云档）
    static func keyInfo(cloudASRProbe: Bool) -> String {
        let base = LLMCatalog.keyStorageNote + "\n" + LLMCatalog.newAccountNote
        guard cloudASRProbe else { return base }
        return base + "\n" + tr("开着云端识别，这把 Key 直接拿识别端点验，连模型有没有开通一起验到。",
                                "With cloud recognition on, the key is verified against the recognition endpoint, which also proves the model is enabled.")
    }

    /// 云端识别那颗 ⓘ：上传、计费、开通、留存、回落——五件事各一句，全在这里，别处不再复述。
    ///
    /// 为什么不放进 PrivacyCopy：那六句讲的是**默认状态**（关于页与引导页），而云端识别是用户
    /// 另点出来的一档，它的代价只该出现在做这个选择的地方。同一个事实仍然只写一处。
    static var cloudRecognitionInfo: String {
        tr("每段录音都会上传给阿里云识别，按音频秒数计费（约每小时 0.13 美元）。第一次用之前要在百炼控制台把这个模型开通一次。阿里云声明不拿这些数据训练模型，但会保存调用数据，没有公布保留期。云端出错时自动改用本机模型再识别一遍。",
           "Every recording is uploaded to Alibaba for recognition, billed by the second (about $0.13 per hour) directly by the provider. Before the first use, enable the model once in the Alibaba Model Studio console. Alibaba states this data is not used to train models, but it does store data generated by API calls, with no published retention period. If the cloud call fails, MicType re-runs recognition on this Mac.")
    }

    static var personalInfo: String {
        tr("「关于我」例如「署名用 Gen」「邮件偏正式、聊天随意」，按住说指令、草拟邮件时会代入。\n「自定义规则」例如「英文术语保留原文」「数字用阿拉伯数字」。两个框都会跟着请求发给服务商。",
           "About me, for example \"sign as Gen\" or \"formal in email, casual in chat\" — voice commands use it when drafting.\nCustom rules, for example \"keep English jargon untranslated\" or \"use Arabic numerals\". Both boxes go to your provider with the request.")
    }

    /// 「高级」那颗 ⓘ：共用的一段 + 这一家型号的一句。每一档都要过 120 字那条线
    static func advancedInfo(provider: LLMProvider) -> String {
        let shared = tr("「模型」下拉一次改两个型号，这里可以分开设：润色每句都跑，求快求省；指令低频，求质量。「刷新」问端点它当前有哪些型号。",
                        "The Model drop-down above writes both model fields at once; here you can split them: polish runs on every sentence and wants speed and low cost, while commands are rare and want quality. Refresh asks the endpoint what it serves today.")
        switch provider {
        case .openai:
            return shared + tr("\nluna 最便宜，terra 平衡，sol 旗舰，astra 最强也最贵。",
                               "\nluna is the cheapest, terra is balanced, sol is the flagship, astra is the strongest and priciest.")
        case .deepseek:
            return shared + tr("\ndeepseek-flash 快且便宜，润色时自动关掉思考模式；deepseek-v4-pro 更强。",
                               "\ndeepseek-flash is fast and cheap — thinking mode is turned off for polish; deepseek-v4-pro is stronger.")
        case .qwen:
            return shared + tr("\nqwen3.8-max 是当前代旗舰，qwen-max 是跟着换代走的稳定别名。",
                               "\nqwen3.8-max is the current flagship; qwen-max is a stable alias that follows each new generation.")
        case .custom:
            return shared + tr("\n这一档没有内置清单：型号名照服务商文档填，或点「刷新」。",
                               "\nNo built-in list here: type the model id from your provider's docs, or hit Refresh.")
        case .local:
            return shared + tr("\n填你本机已经拉下来的模型名，例如 Ollama 里的 llama3.1:8b。",
                               "\nUse the model you have pulled locally, such as llama3.1:8b in Ollama.")
        }
    }

    static var cloudCaptions: [String] {
        [usageLocalOnly, usageWithAI, modelNameInAdvanced, personalBoxesShared, splitModelsRationale,
         localModelNeedsNoKey, cloudRecognitionCost, cloudRecognitionOff,
         hostAutoDetected, hostFilledManually]
    }

    static var cloudInfos: [String] {
        [usageInfo, providerInfo, keyInfo(cloudASRProbe: false), keyInfo(cloudASRProbe: true),
         cloudRecognitionInfo, personalInfo]
            + LLMProvider.allCases.map { advancedInfo(provider: $0) }
    }

    // MARK: - 概览（权限横幅：缺了才出现，一行 + 一颗按钮）

    static var microphoneMissing: String {
        tr("麦克风还没授权，录不到声音", "Microphone is not granted: nothing is recorded")
    }

    static var accessibilityMissing: String {
        tr("辅助功能还没授权，热键无效", "Accessibility is not granted: no hotkey, no typing")
    }

    static var overviewCaptions: [String] {
        [microphoneMissing, accessibilityMissing]
    }

    // MARK: - 边界状态（一行结论 + 一颗按钮，永远不写成一段话）

    /// Fn / 🌐 不在可选那三档里了，但老设置和导入的设置文件仍然能把它存进来
    static var fnNeedsSystemSetting: String {
        tr("Fn / 🌐 要先在系统设置里改成「不执行任何操作」。",
           "Set the 🌐 key to \"Do Nothing\" in System Settings first.")
    }

    /// 选了「只用本地」但钥匙串里那把 Key 还在：按住说指令照样计费
    static func storedKeyWhileLocalOnly(provider: String) -> String {
        tr("钥匙串里还存着 \(provider) 的 Key，按住说指令仍会计费。",
           "A \(provider) key is still in your Keychain; hold-to-command keeps billing you.")
    }

    static var polishOffInMenuBar: String {
        tr("润色在菜单栏里关着，轻点只出识别原文。",
           "Polish is switched off in the menu bar, so tapping gives the raw transcript.")
    }

    /// 4.0.0 的「云端 · OpenAI」识别：界面上已经没有这一档，设置里可能还存着
    static var legacyOpenAICloudRecognition: String {
        tr("还在用 OpenAI 云端识别，每段录音都会上传。",
           "This Mac still uses OpenAI cloud recognition, so every take is uploaded.")
    }

    /// 识别停在阿里云、服务商却换走了：那个开关只在阿里云档渲染，于是界面上没有关掉它的控件
    static var strandedAlibabaRecognition: String {
        tr("识别还走着阿里云（按秒计费），服务商却不是它。",
           "Recognition still goes to Alibaba (billed per second) although your provider is not Alibaba.")
    }

    /// 官方几档的地址被老版本改过：看不见的自定义地址是查不出来的故障
    static var endpointOverridden: String {
        tr("这一档的接口地址被改过：", "This provider's endpoint was overridden: ")
    }

    static func endpointConfiguredByImport(provider: String) -> String {
        tr("「\(provider)」的地址改由「导入设置…」配置，现有配置照常工作。",
           "The endpoint for \(provider) is configured through Import Settings now; your current setup keeps working.")
    }

    static var hostMalformed: String {
        tr("这串不像接入地址，清空即交回自动探测。",
           "That does not look like a host name. Clear it to hand the job back to auto-detection.")
    }

    static var hostNotDetectedYet: String {
        tr("接入地址还没试出来。", "The endpoint has not been detected yet.")
    }

    static var hostInUse: String {
        tr("已试通的接入地址：", "Endpoint in use: ")
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
        [fnNeedsSystemSetting, storedKeyWhileLocalOnly(provider: "OpenAI"), polishOffInMenuBar,
         legacyOpenAICloudRecognition, strandedAlibabaRecognition, endpointOverridden,
         endpointConfiguredByImport(provider: "Ollama"), hostMalformed, hostNotDetectedYet,
         hostInUse, modelReady, modelNotDownloaded, modelNoLongerListed,
         modelUpgradeAvailable, modelHasNewRevision, modelNeedsAppUpdate(version: "4.1.0")]
    }

    // MARK: - 预算表（单测按这几张表逐条量）

    static var allCaptions: [String] {
        inputCaptions + recognitionCaptions + cloudCaptions + overviewCaptions
    }

    static var allInfos: [String] {
        inputInfos + recognitionInfos + cloudInfos
    }
}
