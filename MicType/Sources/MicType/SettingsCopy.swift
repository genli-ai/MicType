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

    /// 录音那颗 ⓘ：草稿落在哪儿 + 录音上限那一整句（数字全部来自常量，见 recordingLimitCopy）。
    ///
    /// **"自动收尾不是丢弃"那一句不在这里写**：recordingLimitCopy 的末尾正写着
    /// 「到上限自动收尾，说过的内容全部识别并插入」——同一颗气泡里说两遍，读的人会以为是两件事。
    static var recordingInfo: String {
        tr("草稿只在悬浮窗里，不落到光标处。\n",
           "The live draft stays in the floating window and never reaches your cursor.\n")
            + DictationController.recordingLimitCopy
    }

    /// 行为那颗 ⓘ：**只说怎么操作**。
    ///
    /// 「存在哪儿、最多几条、不上传」那一句不在这里写：它是一句隐私陈述，出处只有一个
    /// （HistoryStore.storageNote，关于页逐句摆出来）。4.1.0 之前这里自己写了一版
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

    /// 「输入」页在屏幕上摆着的说明（录音上限那一行由 DictationController 现算，一并计入预算）
    static var inputCaptions: [String] {
        [hotkeyGestures, autoStopOff, draftNeedsLocalModel, draftOverlayOnly,
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
        tr("云端档：「识别」量的是往返", "Cloud engine: the ASR figure is a round trip")
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

    /// 识别模型那颗 ⓘ。
    ///
    /// **回落那一句不在这里**：「云端识别开着时本机模型还管草稿与回落」是云端识别那一档的事实，
    /// 写在做那个选择的地方（cloudRecognitionInfo）。控件旁边那行 localModelStillUsed 是它的一句话版本。
    static var modelInfo: String {
        tr("Qwen3-ASR：约 30 种语言 + 22 种中文方言，自动检测语言，识别完全在本机进行，模型来自 HuggingFace。1.7B 更准但不太吃词汇表热词，夹英文专名的口述建议用推荐档。",
           "Qwen3-ASR: about 30 languages plus 22 Chinese dialects, automatic language detection, fully on-device, downloaded from HuggingFace. The 1.7B model is more accurate but responds less to vocabulary hotwords, so speech with embedded English names does better on the recommended one.")
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

    /// 同一段的第二种：**云端识别开着的时候**这一行绝不能还写着"本机识别"。
    /// 4.1.0 之前这一行只看「使用方式」那一档，而 AISetup.mode 把"引擎是云端"也算成「本地 + AI」
    /// ——于是开着阿里云识别的人，在这一页读到的第一句话是"识别在本机"，而每段录音都在上传。
    static var usageWithCloudRecognition: String {
        tr("云端识别，再交服务商润色", "Recognized in the cloud, then polished by your provider")
    }

    /// 「使用方式」那一段下面那一行到底说哪一句。**纯函数**：判错了不会崩，但会在
    /// 每段录音都在上传的那一刻对着用户说"识别在本机"，所以由单测钉住。
    ///
    /// 判据是**识别引擎本身**，不是「使用方式」那一档——AISetup.mode 把"引擎是云端"也算成
    /// 「本地 + AI」，只看档位就永远选不到云端那一句。
    static func usageCaption(mode: AIUsageMode, engine: RecognitionEngineChoice) -> String {
        guard mode != .localOnly else { return usageLocalOnly }
        return engine.isCloud ? usageWithCloudRecognition : usageWithAI
    }

    /// 其他兼容服务 / 本机模型没有内置型号：指路「高级」，而不是摆一个点了没反应的下拉
    static var modelNameInAdvanced: String {
        tr("型号名在下面的「高级」里填", "Type the model id under Advanced below")
    }

    /// 「模型」下拉下面那一行。**只说这一个选择管到哪里**：4.1.1 起润色和指令永远是同一个
    /// 型号（用户 2026-09-20 拍板），"分开设"那条路连同「高级」里的两个输入框一起没了。
    /// 型号名不在这句话里重复——下拉自己写着它。
    static var modelUsedForBoth: String {
        tr("润色和指令都用它", "Used for polish and commands")
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

    /// 选择器上看着的这一档还没配 Key：它现在只是**预览**，生效的仍然是上一档
    static var providerNotSetUp: String {
        tr("这一档未配置", "Not set up")
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
        tr("留空自动探测", "Leave empty to auto-detect")
    }

    static var hostFilledManually: String {
        tr("填了地址就只用它，不再探测", "With an endpoint filled in, MicType stops auto-detecting")
    }

    /// 使用方式那颗 ⓘ。两句话都**只许说代码真会做的事**：
    ///   • 「只用本地」写回的是"润色关掉 + 识别回本机"（AISetup.localOnlyWrites），**不删 Key**，
    ///     而指令路径只看 LLMClient.isConfigured、不看档位——所以这一档下按住说指令照样会计费
    ///     （storedKeyWhileLocalOnly 那条边界说的就是这件事）。写成"那一档没有指令"就是当面说假话。
    ///   • 「本地 + AI」下识别在哪儿，由下面那个「云端识别」开关决定，不是这一档决定的。
    static var usageInfo: String {
        tr("「只用本地」：识别和输入全在这台 Mac 上，不联网、不花钱；按住说指令仍然要有 Key，这一档不替你删 Key。\n「本地 + AI」：文字交给你选的服务商润色，按住说指令也走这家；识别在本机还是云端，看阿里云档下那个开关。",
           "On-device only: recognition and typing all happen on this Mac — no network, no cost. Hold-to-command still needs a key, and this mode does not remove one.\nOn-device + AI: your text is polished by the provider you pick, and hold-to-command uses the same one; whether recognition runs here or in the cloud is set by the Cloud recognition switch under Alibaba Cloud.")
    }

    /// 服务商那颗 ⓘ。4.1.1 起第一句必须说清**什么时候才算换过去**：选择器点一下只是预览，
    /// 钥匙串里有这一档的 Key 才真的换（AISetup.adoptsProvider）。选择器旁边那枚
    /// 「正在使用 ✓」写的就是这一刻生效的是哪一家。
    static var providerInfo: String {
        tr("换一家只要贴那一家的 Key，验证通过才真的换过去；每档各有一条钥匙串条目，换回来不用重贴。\n「其他 OpenAI 兼容服务」与「本机模型」改由「导入设置…」配置。",
           "Switching means pasting that provider's key, and the switch takes effect only once that key verifies. Each provider has its own Keychain entry, so switching back needs no re-paste.\nOther OpenAI-compatible services and on-device models are configured through Import Settings now.")
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
           "Every recording is uploaded to Alibaba Cloud for recognition, billed by the second (about $0.13 per hour) directly by the provider. Before the first use, enable the model once in the Alibaba Cloud Model Studio console. Alibaba Cloud states this data is not used to train models, but it does store data generated by API calls, with no published retention period. If the cloud call fails, MicType re-runs recognition on this Mac.")
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

    /// 「模型」那颗 ⓘ：这一家的型号各是什么来头。**这句话属于做选择的地方**——
    /// 4.1.0 之前它挂在「高级」那颗 ⓘ 上，而下拉就在上面一段，要点开另一段才读得到。
    /// 每一档都要过 120 字那条线。
    static func cloudModelInfo(provider: LLMProvider) -> String {
        let shared = tr("润色每句话都要跑一次，指令偶尔跑一次，两者用同一个型号。换代之后旧型号名可能直接 404，点「高级 → 刷新模型列表」问端点现在有哪些。",
                        "Polish runs on every sentence and commands run now and then; both use this one model. After a generation change an old model id can simply 404 — use Advanced and Refresh to ask the endpoint what it serves today.")
        switch provider {
        case .openai:
            return shared + tr("\nluna 最便宜，terra 平衡，sol 旗舰，astra 最强也最贵。",
                               "\nluna is the cheapest, terra is balanced, sol is the flagship, astra is the strongest and priciest.")
        case .deepseek:
            return shared + tr("\ndeepseek-flash 快且便宜，润色时不思考；deepseek-v4-pro 更强。",
                               "\ndeepseek-flash is fast and cheap — thinking mode is turned off for polish; deepseek-v4-pro is stronger.")
        case .qwen:
            return shared + tr("\nqwen3.8-max 是当前代旗舰，qwen-max 是跟着换代走的稳定别名。",
                               "\nqwen3.8-max is the current flagship; qwen-max is a stable alias that follows each new generation.")
        case .custom:
            return shared + tr("\n这一档没有内置清单：型号名照服务商文档填。",
                               "\nNo built-in list here: type the model id from your provider's docs.")
        case .local:
            return shared + tr("\n填你本机已经拉下来的模型名，例如 Ollama 里的 llama3.1:8b。",
                               "\nUse the model you have pulled locally, such as llama3.1:8b in Ollama.")
        }
    }

    /// 「高级」那颗 ⓘ。4.1.1 之后这一段只剩真正少见的事（分开设型号、温度、区域都拿掉了）。
    /// - hasModelMenu: 这一档有内置型号清单（三家官方档）。没有的那两档多一个型号名输入框
    ///   和「刷新」，ⓘ 也就多一句——**说的只能是屏幕上真有的控件**。
    static func advancedInfo(hasModelMenu: Bool) -> String {
        let base = tr("「测试模型」拿当前型号真发一次最短请求，报往返毫秒数，不动任何设置。",
                      "Test the model sends one real minimal request on the current model and reports the round trip; it changes no settings.")
        guard !hasModelMenu else { return base }
        return base + tr("\n这一档没有内置清单：型号名照服务商文档填，「刷新」问端点它现在有哪些。",
                         "\nThis provider has no built-in list: type the model id from its docs, or hit Refresh to ask the endpoint what it serves.")
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

    /// 优先处理那颗 ⓘ。这一段只在 OpenAI 档出现（AISetup.showsPriorityToggle），
    /// 所以不必再说一遍"只有 OpenAI 有"。
    static var priorityInfo: String {
        tr("付更高的 token 单价换更低、更稳的延迟。服务商仍可能把这次请求降回普通档，真降了下面会写出来。",
           "Pays a higher token price for lower, steadier latency. The provider can still serve the request on the standard tier, and the line below says so when it does.")
    }

    /// 一次性状态快照（"上一次那趟实际跑在哪一档"），不是控件说明——所以不进 captions，
    /// 但仍然只写一处，免得和 LLMCatalog.serviceTierName 拼出两种说法
    static var lastServiceTier: String {
        tr("上一次请求实际跑在：", "Last request actually ran at: ")
    }

    static var cloudCaptions: [String] {
        [usageLocalOnly, usageWithAI, usageWithCloudRecognition,
         providerNotSetUp, modelNameInAdvanced, modelUsedForBoth, customRulesPlaceholder,
         localModelNeedsNoKey, cloudRecognitionCost, cloudRecognitionOff,
         hostAutoDetected, hostFilledManually, webSearchUnsupported]
    }

    static var cloudInfos: [String] {
        [usageInfo, providerInfo, keyInfo(cloudASRProbe: false), keyInfo(cloudASRProbe: true),
         cloudRecognitionInfo, customRulesInfo, webSearchInfo, priorityInfo,
         advancedInfo(hasModelMenu: true), advancedInfo(hasModelMenu: false)]
            + LLMProvider.allCases.map { cloudModelInfo(provider: $0) }
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

    static var hostMalformed: String {
        tr("这串不像接入地址，清空即交回自动探测。",
           "That does not look like an endpoint. Clear it to hand the job back to auto-detection.")
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
        [storedKeyWhileLocalOnly(provider: "OpenAI"), polishOffInMenuBar,
         legacyOpenAICloudRecognition, strandedAlibabaRecognition, launchAtLoginFailed,
         endpointOverridden,
         endpointConfiguredByImport(provider: "Ollama"), hostMalformed, hostNotDetectedYet,
         hostInUse, modelReady, modelNotDownloaded, modelNoLongerListed,
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
        inputInfos + recognitionInfos + cloudInfos
    }
}
