import Foundation

// MARK: - 热键选项

enum HotkeyChoice: String, CaseIterable {
    case rightOption
    case rightCommand
    case rightControl
    case rightShift
    case leftOption
    case leftCommand
    case leftControl
    case fn

    /// 设置里**摆出来**的三个选项（用户 2026-09-19 拍板）。右侧三颗修饰键日常几乎不单独用，
    /// 误触最少；Fn / 🌐 要先去系统设置里把系统的那一层关掉，左侧几颗天天参与 ⌘C、⌥← 这类组合键
    /// ——两类都需要先给用户上一课，摆在选择器里等于把坑一起摆出来。
    ///
    /// `allCases` 仍然是全集：老设置里存着的左侧键 / Fn 照常工作、照常显示全名，
    /// 只是不再推荐给新用户（选择器会把"他正在用的那一颗"额外列出来，见设置页）。
    static let offered: [HotkeyChoice] = [.rightOption, .rightCommand, .rightControl]

    /// 修饰键的物理键码（左右两侧是不同的键码，所以"只用右侧"是真的只认右侧那颗）
    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .rightShift: return 60
        case .leftOption: return 58
        case .leftCommand: return 55
        case .leftControl: return 59
        case .fn: return 63
        }
    }

    var flagMask: UInt {
        switch self {
        case .rightOption, .leftOption: return 1 << 19     // NSEvent.ModifierFlags.option
        case .rightCommand, .leftCommand: return 1 << 20   // NSEvent.ModifierFlags.command
        case .rightControl, .leftControl: return 1 << 18   // NSEvent.ModifierFlags.control
        case .rightShift: return 1 << 17                   // NSEvent.ModifierFlags.shift
        case .fn: return 1 << 23                           // NSEvent.ModifierFlags.function
        }
    }

    /// 这一颗键自己的"设备相关位"（IOLLEvent.h 的 NX_DEVICE*KEYMASK，左右各一位，
    /// 就藏在 NSEvent.modifierFlags.rawValue 的低位里）。flagMask 那种合并位不分左右，
    /// 左手按着左 ⌥ 时右 ⌥ 的松开沿会被误判成按下沿，所以判按下/松开一律先看这里。
    /// Fn 没有设备相关位，也没有"另一侧"，返回 0 表示"用合并位判"。
    var deviceMask: UInt {
        switch self {
        case .leftControl: return 0x0000_0001   // NX_DEVICELCTLKEYMASK
        case .rightShift: return 0x0000_0004    // NX_DEVICERSHIFTKEYMASK
        case .leftCommand: return 0x0000_0008   // NX_DEVICELCMDKEYMASK
        case .rightCommand: return 0x0000_0010  // NX_DEVICERCMDKEYMASK
        case .leftOption: return 0x0000_0020    // NX_DEVICELALTKEYMASK
        case .rightOption: return 0x0000_0040   // NX_DEVICERALTKEYMASK
        case .rightControl: return 0x0000_2000  // NX_DEVICERCTLKEYMASK
        case .fn: return 0
        }
    }

    /// 同名修饰键左右两侧的设备相关位之和。用来判断"这条事件到底报不报设备位"：
    /// 两侧都是 0 说明设备位不可用（或这颗键确实松了），那就退回合并位，绝不能因此判不出按下。
    var deviceMaskPair: UInt {
        switch self {
        case .leftControl, .rightControl: return 0x0000_0001 | 0x0000_2000
        case .rightShift: return 0x0000_0002 | 0x0000_0004   // 左 Shift 不是可选热键，但要一起看
        case .leftCommand, .rightCommand: return 0x0000_0008 | 0x0000_0010
        case .leftOption, .rightOption: return 0x0000_0020 | 0x0000_0040
        case .fn: return 0
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: return tr("右 Option (⌥)", "Right Option (⌥)")
        case .rightCommand: return tr("右 Command (⌘)", "Right Command (⌘)")
        case .rightControl: return tr("右 Control (⌃)", "Right Control (⌃)")
        case .rightShift: return tr("右 Shift (⇧)", "Right Shift (⇧)")
        case .leftOption: return tr("左 Option (⌥)", "Left Option (⌥)")
        case .leftCommand: return tr("左 Command (⌘)", "Left Command (⌘)")
        case .leftControl: return tr("左 Control (⌃)", "Left Control (⌃)")
        case .fn: return tr("Fn 地球键 (🌐)", "Fn Globe key (🌐)")
        }
    }

    /// 句子里用的键名：**永远是全名**，只是不带括号里的符号。
    ///
    /// 4.0.0 这里是 `R⌥` / `L⌘` 这种缩写，出现在菜单栏第一行和引导的每一句话里——
    /// 用户 2026-09-19 实测反馈：没人看得懂那是"右 Option"。一个每天要照着做的动作，
    /// 名字必须是能照着念出来的（「轻点 右 Option」），不能是只有作者认得的记号。
    var plainName: String {
        switch self {
        case .rightOption: return tr("右 Option", "Right Option")
        case .rightCommand: return tr("右 Command", "Right Command")
        case .rightControl: return tr("右 Control", "Right Control")
        case .rightShift: return tr("右 Shift", "Right Shift")
        case .leftOption: return tr("左 Option", "Left Option")
        case .leftCommand: return tr("左 Command", "Left Command")
        case .leftControl: return tr("左 Control", "Left Control")
        // 和别的键一样：句子里读得顺的全名。4.0.1 这里是「Fn / 🌐 地球键」，
        // 嵌进菜单栏第一行就成了 "Tap Fn / 🌐 Globe key to dictate"——一句话里夹一个斜杠和一个表情
        case .fn: return tr("Fn 地球键", "Fn Globe key")
        }
    }

    /// 左侧修饰键天天参与 ⌘C / ⌥← 这类组合键，单独轻点的机会少、也更容易误触，选中时给一句提醒
    var isLeftSideModifier: Bool {
        switch self {
        case .leftOption, .leftCommand, .leftControl: return true
        default: return false
        }
    }
}

// MARK: - 润色档位

enum PolishLevel: String, CaseIterable {
    case off     // 仅本地识别
    case smart   // 自适应润色：短句轻清理，长段混乱口述自动重构

    var displayName: String {
        switch self {
        case .off: return tr("仅识别（最快，完全不联网）",
                             "Transcribe only (fastest, fully offline)")
        case .smart: return tr("AI 润色（自适应：短句轻清理，长口述自动重构）",
                               "AI polish (adaptive: light cleanup or full restructuring)")
        }
    }
}

// MARK: - 悬浮窗位置

/// 悬浮窗落在屏幕的哪儿。默认底部居中 = 3.2 以来的老位置，升级的用户什么都不用动。
/// 多屏永远跟随鼠标所在的那块屏，这个设置只决定屏幕内的落点。
enum OverlayPosition: String, CaseIterable {
    case bottomCenter
    case topCenter
    case nearCursor

    var displayName: String {
        switch self {
        case .bottomCenter: return tr("底部居中（默认）", "Bottom center (default)")
        case .topCenter: return tr("顶部居中", "Top center")
        case .nearCursor: return tr("跟随鼠标指针", "Near the mouse pointer")
        }
    }
}

// MARK: - 大模型服务商

enum LLMProvider: String, CaseIterable {
    case openai
    case deepseek
    /// 通义千问（DashScope 兼容模式）。与自带的 Qwen3-ASR 同一家族，中国大陆可直连。
    case qwen
    /// 任意 OpenAI 兼容端点（Kimi、Gemini 兼容层、z.ai、OpenRouter、自建网关…）——地址由用户填。
    case custom
    /// 本机模型（Ollama / LM Studio）：完全不出网、不花钱、**可以不填 API Key**。
    case local

    /// 用户认得的名字。`.qwen` 这一档 4.0.1 起一律叫**阿里云**：
    /// 「Qwen」「DashScope」「百炼」是三个内部名字，而用户手里那把 Key 来自阿里云控制台。
    var displayName: String {
        switch self {
        case .openai: return "OpenAI (GPT)"
        case .deepseek: return "DeepSeek"
        case .qwen: return tr("阿里云", "Alibaba Cloud")
        case .custom: return tr("其他 OpenAI 兼容服务", "Other OpenAI-compatible service")
        case .local: return tr("本机模型", "Local model")
        }
    }

    /// 分段选择器里的名字：三档并排，名字要短到不换行。
    var segmentName: String {
        switch self {
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .qwen: return tr("阿里云", "Alibaba Cloud")
        case .custom: return tr("其他服务", "Other service")
        // 「本机模型」：和 displayName 用同一个英文名。分段选择器写 "On-device"、
        // 底下那行边界状态写 "Local model"，英文用户会以为屏幕上是两个东西
        case .local: return tr("本机模型", "Local model")
        }
    }

    /// 徽章那种放不下长名字的地方用短名
    var shortName: String {
        switch self {
        case .openai: return "GPT"
        case .deepseek: return "DeepSeek"
        case .qwen: return tr("阿里云", "Alibaba")
        case .custom: return tr("其他", "Other")
        case .local: return tr("本机", "Local")
        }
    }

    /// 每个服务商一条独立的钥匙串条目：换服务商试用时互不覆盖（老用户的两条保持原名不动）
    var keychainAccount: String {
        switch self {
        case .openai: return "openai_api_key"
        case .deepseek: return "deepseek_api_key"
        case .qwen: return "qwen_api_key"
        case .custom: return "custom_api_key"
        case .local: return "local_api_key"
        }
    }

    /// 本机模型不需要 Key：Ollama 要求填但忽略内容，LM Studio 的示例压根不带凭据。
    /// 所以这一档的"没填 Key"是**正常状态**，不是配置错误——整条链路都要容忍空 Key。
    var requiresAPIKey: Bool { self != .local }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com"
        case .qwen: return LLMCatalog.qwenBaseURL(region: .international, workspaceID: "")
        case .custom: return ""
        case .local: return LLMCatalog.LocalRuntime.ollama.baseURL
        }
    }
}

// MARK: - 使用方式（AI 这一整页只有这一个决定）

/// 「只用本地」还是「本地 + AI」。用户 2026-09-19 拍板：配置只做一个决定，
/// 选了 AI 再选**一个**服务商、贴**一把** Key，别的全收进「高级」。
enum AIUsageMode: String, CaseIterable {
    case localOnly
    case withAI

    var displayName: String {
        switch self {
        // 英文侧一律叫 on-device：这一档说的是"识别与输入都在这台 Mac 上"，
        // 而 "Local" 在英文界面里已经是本机大模型那一档的名字（LLMProvider.local）
        case .localOnly: return tr("只用本地", "On-device only")
        case .withAI: return tr("本地 + AI", "On-device + AI")
        }
    }
}

/// 「使用方式」这个决定要落到哪几条设置上。
///
/// 全是**纯函数**：这一层判错了不会崩，但会把音频送上云端（本该是本地档）、
/// 或者让换过服务商的人还在往上一家传音频，所以每条都由单测钉住。
enum AISetup {

    /// 现在落在哪一档。**两个条件都满足才算「只用本地」**：润色关着、识别也在本机。
    /// 只看润色档位的话，从菜单栏关掉润色的人会看到一页「只用本地」，而云端识别还开着
    /// ——那就成了一条看不见的设置。
    static func mode(polishLevel: PolishLevel, engine: RecognitionEngineChoice) -> AIUsageMode {
        (polishLevel == .off && !engine.isCloud) ? .localOnly : .withAI
    }

    /// 选「只用本地」要写回什么：润色关掉、识别回本机（音频从此不出这台 Mac）。
    static func localOnlyWrites() -> (polish: PolishLevel, engine: RecognitionEngineChoice) {
        (.off, .local)
    }

    /// 选「本地 + AI」时润色该回到哪一档：关着就打开，已经开着就一个字都别动。
    static func polishAfterEnablingAI(_ current: PolishLevel) -> PolishLevel {
        current == .off ? .smart : current
    }

    /// 服务商 + 「识别也用云端」那个开关 → 识别引擎该是哪一档。
    ///
    /// 云端识别只剩阿里云这一档（OpenAI 的转写端点 4.0.1 起不再摆出来）。
    /// 换到别的服务商就回本机：不然用户换完服务商，音频还在往阿里云传，而界面上
    /// 已经没有那个开关可以关了。
    static func engine(provider: LLMProvider, cloudRecognition: Bool) -> RecognitionEngineChoice {
        (provider == .qwen && cloudRecognition) ? .cloudAlibaba : .local
    }

    /// 这台 Mac 还停在 4.0.0 的「云端 · OpenAI」识别上吗。
    /// 界面上已经没有这一档了，但设置里可能还存着——必须当面告诉他，并给一颗回本机的按钮，
    /// 绝不替他改（音频出不出这台 Mac 永远由用户自己点）。
    static func showsLegacyOpenAICloudNotice(engine: RecognitionEngineChoice) -> Bool {
        engine == .cloudOpenAI
    }

    /// 云端识别停在阿里云、服务商却不是阿里云——这一状态下 AI 页上那个开关**根本不渲染**
    /// （它只在 provider == .qwen 时出现），于是音频一直在上传，界面上却没有关掉它的控件。
    ///
    /// 怎么走到这一步：4.0.0 的识别页有独立的引擎选择器（与服务商无关），以及设置导入
    /// 直接写 recognitionEngine 不做交叉校验。和 cloudOpenAI 那一条同一个处理：
    /// 当面说 + 给一颗回本机的按钮，**绝不替他改**。
    static func showsStrandedAlibabaCloudNotice(engine: RecognitionEngineChoice,
                                                provider: LLMProvider) -> Bool {
        engine == .cloudAlibaba && provider != .qwen
    }

    /// 换服务商时识别引擎要不要跟着回本机。nil = 不用动。
    ///
    /// 设置页与引导页各有一处换服务商的入口，两处必须做同一件事——4.0.1 里只有设置页做了，
    /// 于是从引导里换走服务商的人，音频还在往阿里云传，而 AI 页上已经没有那个开关了。
    static func engineAfterProviderChange(current: RecognitionEngineChoice,
                                          next: LLMProvider) -> RecognitionEngineChoice? {
        guard current == .cloudAlibaba,
              engine(provider: next, cloudRecognition: true) != .cloudAlibaba else { return nil }
        return .local
    }

    /// 「只用本地」这一档里，钥匙串里还躺着一把能用的 Key：必须当面说一句。
    ///
    /// 这一档写回的只有"润色关掉 + 识别回本机"（见 localOnlyWrites），**指令路径不看档位**
    /// ——按住说指令照样会把选区和这句话发给服务商并计费。不说的话，用户读到的是
    /// 「不联网、不花钱」，而账单上是另一回事。
    static func showsStoredKeyNotice(mode: AIUsageMode, hasCredential: Bool) -> Bool {
        mode == .localOnly && hasCredential
    }
}

// MARK: - 设置键

enum SettingsKeys {
    static let hotkey = "hotkey"
    static let polishEnabled = "polishEnabled"
    static let polishLevel = "polishLevel"
    static let openaiBaseURL = "openaiBaseURL"
    static let chatModel = "chatModel"                     // OpenAI 润色模型（快）
    static let openaiCommandModel = "openaiCommandModel"   // OpenAI 指令模型（强）
    static let deepseekCommandModel = "deepseekCommandModel"
    static let polishTemperature = "polishTemperature"     // 润色温度（默认 0.5）
    static let commandTemperature = "commandTemperature"   // 指令温度（默认 1.0 = 模型默认）
    static let aboutMe = "aboutMe"
    static let customPolishRules = "customPolishRules"
    static let customVocabulary = "customVocabulary"
    static let fillerWords = "fillerWords"                 // 额外的口水词（4.0.2 起界面上没有这一项，内置表自动生效）
    static let playSounds = "playSounds"
    static let restoreClipboard = "restoreClipboard"
    static let autoStopSilenceSeconds = "autoStopSilenceSeconds"  // 静音自动停秒数（0 = 关）
    static let inputDeviceUID = "inputDeviceUID"            // 指定麦克风的 CoreAudio UID（"" = 系统默认）
    static let livePreview = "livePreview"                 // 录音中悬浮窗灰字预览（伪流式）
    static let overlayPosition = "overlayPosition"         // 悬浮窗在屏幕上的落点
    static let keepHistory = "keepHistory"                 // 是否把听写结果记进历史（默认开）
    static let qwenModelRepo = "qwenModelRepo"
    static let recognitionLanguage = "recognitionLanguage"  // 识别语言（"" = 自动检测）
    static let recognitionEngine = "recognitionEngine"      // 识别引擎：local（默认）/ cloudAlibaba / cloudOpenAI
    static let cloudAlibabaModel = "cloudAlibabaModel"      // 云端·阿里云用哪个识别模型
    static let modelCatalogLastCheck = "modelCatalogLastCheck"      // 上次**成功**取到模型目录的时间（epoch 秒，0 = 没成功过）
    static let modelCatalogRetryAfter = "modelCatalogRetryAfter"    // 上次取目录失败后的退避时间点（epoch 秒，0 = 没有）
    static let pendingModelCleanup = "pendingModelCleanup"          // 等着删的旧模型仓库（升级后、首次成功听写前）
    static let pendingCleanupLaunch = "pendingModelCleanupLaunch"   // 换模型发生在第几次启动（删旧模型要求之后至少重启过一次）
    static let pendingCleanupSucceeded = "pendingModelCleanupSucceeded"  // 新模型已经真实听写成功过一次
    static let appLaunchCount = "appLaunchCount"                    // App 启动过多少次（只用来判"换模型之后有没有重启过"）
    static let dismissedModelUpgradeRepo = "dismissedModelUpgradeRepo"  // 用户点过「以后再说」的那个模型仓库

    /// 用户对「这个仓库有新修订」点过「以后再说」时，压住的那一份文件（远端清单指纹）。
    /// 按指纹而不是按仓库存：上游真出下一版时指纹会变，提示该回来。
    static func dismissedModelRefreshFingerprint(_ repo: String) -> String {
        "dismissedModelRefresh_" + repo
    }
    static let llmProvider = "llmProvider"
    static let appLanguage = "appLanguage"
    static let deepseekBaseURL = "deepseekBaseURL"
    static let deepseekModel = "deepseekModel"
    // 4.0.1：区域选择器已从界面拿掉（用户拍板）。这两条留着**只为兼容老设置**——
    // 它们仍是候选主机表最好的排序线索（见 AlibabaEndpoint.candidates），但不再有 UI。
    static let qwenRegion = "qwenRegion"                    // 老设置：DashScope 接入区域
    static let qwenWorkspaceID = "qwenWorkspaceID"          // 老设置：WorkspaceId（主机名第一段）
    static let qwenAPIHost = "qwenAPIHost"                  // 用户自己粘的接入地址（可选，粘了就只用它）
    static let qwenResolvedHost = "qwenResolvedHost"        // 试通并记住的那台主机（本机缓存，不进设置导出）
    static let qwenModel = "qwenModel"
    static let qwenCommandModel = "qwenCommandModel"
    static let customBaseURL = "customBaseURL"              // 自定义端点地址（唯一可见的 URL 输入框）
    static let customModel = "customModel"
    static let customCommandModel = "customCommandModel"
    static let localRuntime = "localRuntime"                // ollama / lmstudio（端口固定）
    static let localModel = "localModel"
    static let localCommandModel = "localCommandModel"
    static let fastTier = "fastTier"                        // service_tier:"fast"（贵一倍换低延迟，默认关）
    static let webSearchEnabled = "webSearchEnabled"        // 指令模式联网搜索（按次计费，默认关）
    static let onboardingCompleted = "onboardingCompleted"  // 首启动引导是否走过（老用户按"已配置好"自动置真）
    static let hotkeyConfirmed = "hotkeyConfirmed"          // 用户在引导第一屏确认过用哪颗键（直接「继续」也算）
    static let onboardingSkippedEssentials = "onboardingSkippedEssentials"  // 他点过「先跳过」：引导不再每次启动拦他，但概览上的徽章照常挂着
    /// 4.0.1 的默认型号迁移真的改掉了哪几处（"旧型号>新型号" 编码，见 LLMCatalog.encodeModelChanges）。
    /// 只存型号名、不存句子：文案按当时的语言现拼（见 CLAUDE.md「i18n 快照字符串」）。
    /// 用户在 AI 页点过「知道了」就清空。
    static let modelMigrationNotice = "modelMigrationNotice"
}

// MARK: - 设置

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            SettingsKeys.hotkey: HotkeyChoice.rightOption.rawValue,
            SettingsKeys.polishEnabled: true,
            SettingsKeys.polishLevel: PolishLevel.smart.rawValue,
            SettingsKeys.openaiBaseURL: "https://api.openai.com/v1",
            SettingsKeys.chatModel: LLMCatalog.defaultModel(for: .openai),
            SettingsKeys.openaiCommandModel: LLMCatalog.defaultModel(for: .openai),
            SettingsKeys.deepseekCommandModel: LLMCatalog.defaultModel(for: .deepseek),
            SettingsKeys.polishTemperature: 0.5,
            SettingsKeys.commandTemperature: 1.0,
            SettingsKeys.aboutMe: "",
            SettingsKeys.customPolishRules: "",
            SettingsKeys.customVocabulary: "",
            SettingsKeys.fillerWords: "",
            SettingsKeys.playSounds: true,
            SettingsKeys.restoreClipboard: true,
            SettingsKeys.autoStopSilenceSeconds: 0.0,
            SettingsKeys.inputDeviceUID: "",
            SettingsKeys.livePreview: true,
            SettingsKeys.overlayPosition: OverlayPosition.bottomCenter.rawValue,
            SettingsKeys.keepHistory: true,
            SettingsKeys.qwenModelRepo: QwenModels.defaultRepo,
            SettingsKeys.recognitionLanguage: RecognitionLanguages.autoCode,
            // 识别引擎默认永远是本地：音频出不出这台 Mac 这种事，只能由用户自己点
            SettingsKeys.recognitionEngine: RecognitionEngineChoice.local.rawValue,
            // 同步识别端点上只有 qwen3-asr-flash（4.0.0 默认的 3.0 打它必 404，见 AlibabaASRModel）
            SettingsKeys.cloudAlibabaModel: AlibabaASRModel.qwen3Flash.rawValue,
            // 模型目录 / 升级的本机状态（不进设置导出：跟这台机器的磁盘绑定）
            SettingsKeys.modelCatalogLastCheck: 0.0,
            SettingsKeys.modelCatalogRetryAfter: 0.0,
            SettingsKeys.pendingModelCleanup: [String](),
            SettingsKeys.pendingCleanupLaunch: 0,
            SettingsKeys.pendingCleanupSucceeded: false,
            SettingsKeys.appLaunchCount: 0,
            SettingsKeys.dismissedModelUpgradeRepo: "",
            SettingsKeys.llmProvider: LLMProvider.openai.rawValue,
            SettingsKeys.deepseekBaseURL: LLMProvider.deepseek.defaultBaseURL,
            SettingsKeys.deepseekModel: LLMCatalog.defaultModel(for: .deepseek),
            SettingsKeys.qwenRegion: LLMCatalog.QwenRegion.international.rawValue,
            SettingsKeys.qwenWorkspaceID: "",
            SettingsKeys.qwenAPIHost: "",
            SettingsKeys.qwenResolvedHost: "",
            SettingsKeys.qwenModel: LLMCatalog.defaultModel(for: .qwen),
            SettingsKeys.qwenCommandModel: LLMCatalog.defaultModel(for: .qwen),
            SettingsKeys.customBaseURL: "",
            SettingsKeys.customModel: "",
            SettingsKeys.customCommandModel: "",
            SettingsKeys.localRuntime: LLMCatalog.LocalRuntime.ollama.rawValue,
            SettingsKeys.localModel: "",
            SettingsKeys.localCommandModel: "",
            // 花钱的开关一律默认关：多付的钱必须是用户自己点下去的
            SettingsKeys.fastTier: false,
            SettingsKeys.webSearchEnabled: false,
            SettingsKeys.onboardingCompleted: false,
            SettingsKeys.hotkeyConfirmed: false,
            SettingsKeys.onboardingSkippedEssentials: false,
        ])

        // 一次性迁移：产品由 VoiceFlow 改名 MicType，defaults 域随 Bundle ID 变更，
        // 把旧域里用户设置过的值（词汇表、档位、Base URL 等）原样搬过来。
        if !d.bool(forKey: "migratedFromVoiceFlow") {
            let legacyPlist = NSHomeDirectory() + "/Library/Preferences/com.ligen.voiceflow.plist"
            if let legacy = NSDictionary(contentsOfFile: legacyPlist) as? [String: Any] {
                let bundleID = Bundle.main.bundleIdentifier ?? "com.ligen.mictype"
                let alreadySet = d.persistentDomain(forName: bundleID) ?? [:]
                for (key, value) in legacy where alreadySet[key] == nil {
                    d.set(value, forKey: key)
                }
            }
            d.set(true, forKey: "migratedFromVoiceFlow")
        }

        // 干净安装（四个模型键一个都没存过）：历史迁移无事可做，直接把标记全部置真。
        // 必须显式跳过——老的 migratedSplitModels 读的是 d.string()，拿到的是**注册默认值**，
        // 它会把这个默认值当成"用户的旧通用模型"搬进指令模型，再把润色降成 nano，
        // 于是新装的用户反而拿不到当前版本的默认型号（3.2.1 以来的老账，v4.0 一并收掉）。
        // 用 persistentDomain 判断"存没存过"：d.object() 会把注册域也算进去，判不出干净安装。
        let storedDomain = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.ligen.mictype") ?? [:]
        let modelKeys = [SettingsKeys.chatModel, SettingsKeys.openaiCommandModel,
                         SettingsKeys.deepseekModel, SettingsKeys.deepseekCommandModel]
        if !modelKeys.contains(where: { storedDomain[$0] != nil }) {
            for flag in ["migratedModelToMini2", "migratedSplitModels", "migratedPolishTo55",
                         LLMCatalog.migrationFlagKey, LLMCatalog.bestDefaultMigrationFlagKey] {
                d.set(true, forKey: flag)
            }
        }

        // 一次性迁移：统一默认模型为 gpt-5.4-mini（质量与速度的平衡点）
        if !d.bool(forKey: "migratedModelToMini2") {
            let current = d.string(forKey: SettingsKeys.chatModel)
            if current == nil || current == "gpt-4o-mini" || current == "gpt-5.4-nano" {
                d.set("gpt-5.4-mini", forKey: SettingsKeys.chatModel)
            }
            d.set(true, forKey: "migratedModelToMini2")
        }

        // 一次性迁移（3.2.1）：润色/指令模型分离——指令继承旧的通用模型，润色降为 nano（速度优先）
        if !d.bool(forKey: "migratedSplitModels") {
            if let old = d.string(forKey: SettingsKeys.chatModel) {
                d.set(old, forKey: SettingsKeys.openaiCommandModel)
            }
            d.set("gpt-5.4-nano", forKey: SettingsKeys.chatModel)
            if let oldDS = d.string(forKey: SettingsKeys.deepseekModel) {
                d.set(oldDS, forKey: SettingsKeys.deepseekCommandModel)
            }
            d.set(true, forKey: "migratedSplitModels")
        }

        // 一次性迁移：润色默认升到 gpt-5.5——结构化成稿能力 nano/mini 跟不动（配合默认结构化 prompt）。
        // 只升「还停在旧自动默认」的用户（nil / gpt-4o-mini / gpt-5.4-nano）；用户手动选过的型号一律不动。
        if !d.bool(forKey: "migratedPolishTo55") {
            let current = d.string(forKey: SettingsKeys.chatModel)
            if current == nil || current == "gpt-4o-mini" || current == "gpt-5.4-nano" {
                d.set("gpt-5.5", forKey: SettingsKeys.chatModel)
            }
            d.set(true, forKey: "migratedPolishTo55")
        }

        // 一次性迁移（v4.0）：型号线整体升到 gpt-5.6 / DeepSeek 新命名。
        // 规则在 LLMCatalog.migrationTo56（纯函数，单测钉死）：**只搬还停在历史自动默认上的用户**，
        // 手选过型号的人一个字都不动；DeepSeek 那几个已下线的型号名必须改，否则每次调用都 404。
        if !d.bool(forKey: LLMCatalog.migrationFlagKey) {
            let current: [String: String?] = [
                SettingsKeys.chatModel: d.string(forKey: SettingsKeys.chatModel),
                SettingsKeys.openaiCommandModel: d.string(forKey: SettingsKeys.openaiCommandModel),
                SettingsKeys.deepseekModel: d.string(forKey: SettingsKeys.deepseekModel),
                SettingsKeys.deepseekCommandModel: d.string(forKey: SettingsKeys.deepseekCommandModel),
            ]
            for (key, value) in LLMCatalog.migrationTo56(current: current) {
                d.set(value, forKey: key)
            }
            d.set(true, forKey: LLMCatalog.migrationFlagKey)
        }

        // 一次性迁移（4.0.1）：默认型号改成各家最好的那一档（用户拍板：默认不能是便宜货）。
        // 规则在 LLMCatalog.migrationToBestDefault（纯函数，单测钉死）：**只搬还停在 4.0.0
        // 那几对自动默认上的用户**（润色便宜一档 + 指令贵一档），手选过型号的人一个字都不动。
        // 必须排在 migrationTo56 之后：那一步刚写进去的值，这一步要按新值判。
        if !d.bool(forKey: LLMCatalog.bestDefaultMigrationFlagKey) {
            var current: [String: String?] = [:]
            for provider in [LLMProvider.openai, .deepseek, .qwen] {
                let keys = LLMCatalog.modelKeys(for: provider)
                // updateValue 而不是下标赋值：值类型本身就是 String?，下标那一路
                // 「存一个 nil」和「把键删掉」长得一模一样，读起来要靠猜
                current.updateValue(d.string(forKey: keys.polish), forKey: keys.polish)
                current.updateValue(d.string(forKey: keys.command), forKey: keys.command)
            }
            for (key, value) in LLMCatalog.migrationToBestDefault(current: current) {
                d.set(value, forKey: key)
            }
            // 4.0.0 的「快」档写进去的那一对，和出厂默认一字不差（见 autoPairs40 的注释），
            // 所以这一步分不出「停在默认」和「明确选过便宜档」。分不出就**说出来**：
            // 改了哪个型号、改成了什么，记一行日志，并在 AI 页上给一次可关掉的提示。
            // OpenAI 那一档 luna → sol 按其自身注释是约 20 倍输入价差，而润色每句话都要跑一次。
            let changes = LLMCatalog.migrationToBestDefaultChanges(current: current)
            if !changes.isEmpty {
                for change in changes {
                    Log.info("Model default migrated from=\(change.from) to=\(change.to)")
                }
                d.set(LLMCatalog.encodeModelChanges(changes), forKey: SettingsKeys.modelMigrationNotice)
            }
            d.set(true, forKey: LLMCatalog.bestDefaultMigrationFlagKey)
        }

        // 一次性迁移（4.0.1）：老设置里的「区域 + WorkspaceId」→ 试通主机缓存。
        //
        // 4.0.1 拿掉了区域选择器，接入地址改成 App 自己试。但候选表只认三个工作空间后缀，
        // 4.0.0 里能选的东京 / 香港 / US 三档一台都拼不出来——这几位用户升上来之后，
        // 润色和识别会被静默改发到北京站或国际站，而探测器永远试不到他真正那台。
        // 把老设置推出来的主机种进缓存，等于"上一次试通的就是它"，升级当天照常能用。
        // 拼不出合法主机名时（WorkspaceId 带下划线）不种：那一支仍然退回区域兜底 + 提示粘地址。
        if !d.bool(forKey: "migratedQwenLegacyHost") {
            let region = LLMCatalog.QwenRegion(rawValue: d.string(forKey: SettingsKeys.qwenRegion) ?? "")
                ?? .international
            if let seed = AlibabaEndpoint.legacyHostSeed(
                region: region,
                workspaceID: d.string(forKey: SettingsKeys.qwenWorkspaceID) ?? "",
                pastedHost: d.string(forKey: SettingsKeys.qwenAPIHost) ?? "",
                resolvedHost: d.string(forKey: SettingsKeys.qwenResolvedHost) ?? "") {
                d.set(seed, forKey: SettingsKeys.qwenResolvedHost)
                Log.info("Qwen legacy host seeded host=\(AlibabaEndpoint.redacted(seed))")
            }
            d.set(true, forKey: "migratedQwenLegacyHost")
        }

        // 一次性迁移（4.0.1）：云端识别模型 qwen-audio-3.0-asr-flash → qwen3-asr-flash。
        //
        // 3.0 只活在异步端点上，打同步端点必然 404（见 AlibabaASRModel）。4.0.0 把它设成了
        // 默认值，所以老设置里存着它的人不在少数；而 4.0.1 已经把识别模型选择器删掉了，
        // 他在界面上无从改回来。404 之后那条自动换模型的路只在「测试识别」那一趟上跑，
        // 日常听写每一次都要白白上传一整段音频再回落本地——所以必须在启动时就改过来。
        if !d.bool(forKey: "migratedCloudASRModelTo3") {
            if d.string(forKey: SettingsKeys.cloudAlibabaModel) == AlibabaASRModel.qwenAudio30Flash.rawValue {
                d.set(AlibabaASRModel.qwen3Flash.rawValue, forKey: SettingsKeys.cloudAlibabaModel)
                Log.info("CloudASR model migrated to=\(AlibabaASRModel.qwen3Flash.rawValue)")
            }
            d.set(true, forKey: "migratedCloudASRModelTo3")
        }

        // 一次性迁移（4.1.0）：hotkeyConfirmed 是这一版新增的"三件必办的事"之一，
        // 老设置里当然没有。引导早就走过的人不该被要求再确认一次快捷键——否则他从
        // 设置里重新打开引导（或被模型缺失带回去）时，最后一屏的「完成」会卡在一件
        // 他几百次听写之前就做过的事上，而界面上没有任何东西说得清卡在哪儿。
        if !d.bool(forKey: "migratedHotkeyConfirmed") {
            if d.bool(forKey: SettingsKeys.onboardingCompleted) {
                d.set(true, forKey: SettingsKeys.hotkeyConfirmed)
            }
            d.set(true, forKey: "migratedHotkeyConfirmed")
        }
    }

    var hotkey: HotkeyChoice {
        get { HotkeyChoice(rawValue: d.string(forKey: SettingsKeys.hotkey) ?? "") ?? .rightOption }
        set { d.set(newValue.rawValue, forKey: SettingsKeys.hotkey) }
    }

    var polishEnabled: Bool {
        get { d.bool(forKey: SettingsKeys.polishEnabled) }
        set { d.set(newValue, forKey: SettingsKeys.polishEnabled) }
    }

    var polishLevel: PolishLevel {
        // 旧值 light/deep 自动迁移为 smart
        get { PolishLevel(rawValue: d.string(forKey: SettingsKeys.polishLevel) ?? "") ?? .smart }
        set { d.set(newValue.rawValue, forKey: SettingsKeys.polishLevel) }
    }

    var openaiBaseURL: String {
        get {
            // 被清空保存过也回退默认——Base URL 永远自动有值，用户只在自定义网关时才需要改
            let v = d.string(forKey: SettingsKeys.openaiBaseURL)?.trimmingCharacters(in: .whitespaces) ?? ""
            return v.isEmpty ? "https://api.openai.com/v1" : v
        }
        set { d.set(newValue, forKey: SettingsKeys.openaiBaseURL) }
    }

    var chatModel: String {
        get { d.string(forKey: SettingsKeys.chatModel) ?? LLMCatalog.defaultModel(for: .openai) }
        set { d.set(newValue, forKey: SettingsKeys.chatModel) }
    }

    var customPolishRules: String {
        get { d.string(forKey: SettingsKeys.customPolishRules) ?? "" }
        set { d.set(newValue, forKey: SettingsKeys.customPolishRules) }
    }

    /// 逗号/换行分隔的专有词汇
    var customVocabulary: String {
        get { d.string(forKey: SettingsKeys.customVocabulary) ?? "" }
        set { d.set(newValue, forKey: SettingsKeys.customVocabulary) }
    }

    /// 词表 / 口水词表共用的分隔符。**必须含 \r**：Windows 端多行文本框产出的换行是 CRLF，
    /// 只认 \n 的话从 Windows 搬过来（设置导入 / 直接粘贴）的每个条目都会拖一个裸 CR，
    /// 之后既会被当成热词送进识别与润色提示，也会让口水词的正则永远匹配不上（静默失效）。
    /// 与 Windows 端 AppSettings.cs 的 [',', '，', '、', '\n', '\r'] 同源。
    static let listSeparators = CharacterSet(charactersIn: ",，、\n\r")

    /// 词汇表解析：普通词条做热词/润色提示；"错写=正写"词条做硬替换（正写同时进热词）。
    /// 一个正写可以挂多个错写：「杰文|捷纹|结文=捷文」——同一个名字的各种听错法不必分行写。
    /// 纯函数（不碰 UserDefaults）以便单测，并与 Windows 端 AppSettings.ParseVocabulary 逐条对齐。
    static func parseVocabulary(_ text: String)
        -> (terms: [String], replacements: [(wrong: String, right: String)]) {
        var terms: [String] = []
        var replacements: [(String, String)] = []
        let raw = text
            .replacingOccurrences(of: "＝", with: "=")
            .replacingOccurrences(of: "｜", with: "|")
        for item in raw.components(separatedBy: listSeparators) {
            let entry = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            // 用 firstIndex(of:) 定位等号，不用 split：split 默认丢弃空段，
            // 「Qwen=」「=捷文」「=」这类半空条目会切出 1 段（甚至 0 段）掉进 else 分支，
            // 把**带等号的整串**当成热词送进 Qwen3-ASR 与润色提示词。
            // Windows 端一律 continue 丢弃（AppSettings.cs），两端行为必须一致。
            if let idx = entry.firstIndex(of: "=") {
                let left = String(entry[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(entry[entry.index(after: idx)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !left.isEmpty, !right.isEmpty else { continue }
                let wrongs = left.split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !wrongs.isEmpty else { continue }
                for wrong in wrongs { replacements.append((wrong, right)) }
                terms.append(right)
            } else {
                terms.append(entry)
            }
        }
        return (terms, replacements)
    }

    /// 「逗号/换行分隔」的简单列表解析（口水词表等），与 Windows 端 ParseFillerWords 同源
    static func parseList(_ text: String) -> [String] {
        text.components(separatedBy: listSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var vocabularyEntries: (terms: [String], replacements: [(wrong: String, right: String)]) {
        Settings.parseVocabulary(customVocabulary)
    }

    var vocabularyTerms: [String] { vocabularyEntries.terms }
    var vocabularyReplacements: [(wrong: String, right: String)] { vocabularyEntries.replacements }

    /// 口水词表原文（逗号/换行分隔），默认空。
    ///
    /// 4.0.2 起界面上**没有这个输入框**了：中/英/阿三套保守词表内置在
    /// TextPostProcessor.builtInFillerWords 里自动生效，没人该为了不打出「嗯」维护一张表。
    /// 这条设置留着是因为老设置和导入的设置文件里可能有内容——照旧作为**额外**的词条生效。
    var customFillerWords: String {
        get { d.string(forKey: SettingsKeys.fillerWords) ?? "" }
        set { d.set(newValue, forKey: SettingsKeys.fillerWords) }
    }

    /// 解析后的额外口水词列表（内置表之外的那几条）
    var fillerWords: [String] { Settings.parseList(customFillerWords) }

    var playSounds: Bool {
        get { d.bool(forKey: SettingsKeys.playSounds) }
        set { d.set(newValue, forKey: SettingsKeys.playSounds) }
    }

    var restoreClipboard: Bool {
        get { d.bool(forKey: SettingsKeys.restoreClipboard) }
        set { d.set(newValue, forKey: SettingsKeys.restoreClipboard) }
    }

    /// 静音自动停：说完后连续这么多秒没有人声就自动收尾。0 = 关闭（默认）。
    /// 默认关是刻意的——"替用户决定他说完了"必须由用户自己打开，手势永远优先。
    var autoStopSilenceSeconds: Double {
        get { d.object(forKey: SettingsKeys.autoStopSilenceSeconds) as? Double ?? 0 }
        set { d.set(max(0, newValue), forKey: SettingsKeys.autoStopSilenceSeconds) }
    }

    /// 指定用哪只麦克风录音（CoreAudio 设备 UID）。"" = 跟随系统默认（默认值，升级的用户什么都不用动）。
    /// 存 UID 不存 AudioDeviceID：后者拔插一次就变。指定的设备开录时不在（没插 / 换了台机器），
    /// AudioRecorder 会退回系统默认并记一条 WARN——**绝不因为一只麦克风不在就让这次录音失败**，
    /// 也绝不替用户把这条设置改掉（下次插回来照旧生效）。
    var inputDeviceUID: String {
        get { d.string(forKey: SettingsKeys.inputDeviceUID) ?? "" }
        set { d.set(newValue, forKey: SettingsKeys.inputDeviceUID) }
    }

    /// 录音中在悬浮窗显示灰色的实时草稿（伪流式预览）。默认开。
    /// 这条只影响"看得见"，永远不影响插入的文字——草稿绝不会进目标应用，
    /// 最终结果永远是松手后重跑的那一遍完整识别。
    var livePreview: Bool {
        get { d.bool(forKey: SettingsKeys.livePreview) }
        set { d.set(newValue, forKey: SettingsKeys.livePreview) }
    }

    /// 悬浮窗落点。只影响"出现在哪"，不影响任何行为；多屏仍然永远跟随鼠标所在那块屏。
    /// 读不出/读到脏值一律回退底部居中——位置这种东西绝不能因为一条坏设置就丢到屏幕外。
    var overlayPosition: OverlayPosition {
        get { OverlayPosition(rawValue: d.string(forKey: SettingsKeys.overlayPosition) ?? "") ?? .bottomCenter }
        set { d.set(newValue.rawValue, forKey: SettingsKeys.overlayPosition) }
    }

    /// 是否把每次听写/指令的结果记进历史（Application Support/history.json，最多 200 条）。
    /// 默认开——历史是菜单栏的一级功能。关掉后立即停止写入，已有的记录留着，
    /// 要清由用户自己点「清空记录」或在历史窗口里逐条删：这类事永远不替他做主。
    var keepHistory: Bool {
        get { d.bool(forKey: SettingsKeys.keepHistory) }
        set { d.set(newValue, forKey: SettingsKeys.keepHistory) }
    }

    /// 润色/技能使用的大模型服务商（GPT 或 DeepSeek，二选一）
    var llmProvider: LLMProvider {
        get { LLMProvider(rawValue: d.string(forKey: SettingsKeys.llmProvider) ?? "") ?? .openai }
        set { d.set(newValue.rawValue, forKey: SettingsKeys.llmProvider) }
    }

    var deepseekBaseURL: String {
        get {
            let v = d.string(forKey: SettingsKeys.deepseekBaseURL)?.trimmingCharacters(in: .whitespaces) ?? ""
            return v.isEmpty ? LLMProvider.deepseek.defaultBaseURL : v
        }
        set { d.set(newValue, forKey: SettingsKeys.deepseekBaseURL) }
    }

    var deepseekModel: String {
        get { d.string(forKey: SettingsKeys.deepseekModel) ?? LLMCatalog.defaultModel(for: .deepseek) }
        set { d.set(newValue, forKey: SettingsKeys.deepseekModel) }
    }

    // MARK: Qwen / 自定义端点 / 本机模型

    /// 老设置：DashScope 接入区域。界面上已经没有它了（4.0.1 拿掉了区域选择器），
    /// 留着是因为老用户选过的那个值仍是候选主机表最好的排序线索。
    /// 读到脏值回退国际站（一条坏设置不该让服务商整档失灵）。
    var qwenRegion: LLMCatalog.QwenRegion {
        get { LLMCatalog.QwenRegion(rawValue: d.string(forKey: SettingsKeys.qwenRegion) ?? "") ?? .international }
        set { d.set(newValue.rawValue, forKey: SettingsKeys.qwenRegion) }
    }

    /// 老设置：区域端点主机名里的 WorkspaceId。同样只剩"候选主机的种子"这一个用途。
    var qwenWorkspaceID: String {
        get { d.string(forKey: SettingsKeys.qwenWorkspaceID) ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    forKey: SettingsKeys.qwenWorkspaceID) }
    }

    /// 用户从百炼控制台粘进来的接入地址（apiHost 或整条 URL 都认）。**可选**：
    /// 空着就由 MicType 自己试（见 AlibabaEndpoint）。粘了就只用它，不再乱试别的主机。
    var qwenAPIHost: String {
        get { d.string(forKey: SettingsKeys.qwenAPIHost) ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    forKey: SettingsKeys.qwenAPIHost) }
    }

    /// 上一次真的试通的那台主机（本机缓存）。有了它，正常使用一次都不再探测。
    var qwenResolvedHost: String {
        get { d.string(forKey: SettingsKeys.qwenResolvedHost) ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    forKey: SettingsKeys.qwenResolvedHost) }
    }

    /// Qwen 的 Base URL 永远是推出来的，没有 URL 输入框。
    /// 优先用试通/粘贴的那台主机——**润色与云端识别同一台主机**，一处试通两边都对；
    /// 都还没有就退回老设置那条（区域 + WorkspaceId），老用户升级上来第一次仍然能用。
    ///
    /// 这里**不读钥匙串**（每次界面重算、每次请求都会走到这个属性，Security 框架那一趟
    /// 不能挂在这种地方）。可云端识别那条路是带着 Key 去拼候选主机的：工作空间那几台
    /// 是从 `sk-ws-xxxx` 这个形状认出来的，两边喂的东西不一样就会一个发去工作空间主机、
    /// 一个发去 dashscope-intl，必有一边 401。所以 Key 里的 WorkspaceId 在**验证那一刻**
    /// 就落盘（CloudASRSettings.rememberWorkspace），这条路从设置里读它，两边同源。
    var qwenBaseURL: String {
        let host = CloudASRSettings.alibabaHost(pastedHost: qwenAPIHost,
                                                resolvedHost: qwenResolvedHost,
                                                workspace: qwenWorkspaceID,
                                                legacyRegionSlug: qwenRegion.regionSlug,
                                                apiKey: "")
        let derived = AlibabaEndpoint.compatibleBaseURL(host: host)
        return derived.isEmpty
            ? LLMCatalog.qwenBaseURL(region: qwenRegion, workspaceID: qwenWorkspaceID)
            : derived
    }

    var qwenModel: String {
        get { d.string(forKey: SettingsKeys.qwenModel) ?? LLMCatalog.defaultModel(for: .qwen) }
        set { d.set(newValue, forKey: SettingsKeys.qwenModel) }
    }

    var qwenCommandModel: String {
        get { d.string(forKey: SettingsKeys.qwenCommandModel) ?? LLMCatalog.defaultModel(for: .qwen) }
        set { d.set(newValue, forKey: SettingsKeys.qwenCommandModel) }
    }

    /// 自定义端点地址。**唯一**可见的 Base URL 输入框——官方几档的地址由 MicType 自己拼，
    /// 免得「Base URL 被改过却看不出来」变成一个查不出来的故障（见 SettingsView 的复位提示）。
    var customBaseURL: String {
        get { d.string(forKey: SettingsKeys.customBaseURL)?.trimmingCharacters(in: .whitespaces) ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    forKey: SettingsKeys.customBaseURL) }
    }

    var customModel: String {
        get { d.string(forKey: SettingsKeys.customModel) ?? "" }
        set { d.set(newValue, forKey: SettingsKeys.customModel) }
    }

    var customCommandModel: String {
        get { d.string(forKey: SettingsKeys.customCommandModel) ?? "" }
        set { d.set(newValue, forKey: SettingsKeys.customCommandModel) }
    }

    var localRuntime: LLMCatalog.LocalRuntime {
        get { LLMCatalog.LocalRuntime(rawValue: d.string(forKey: SettingsKeys.localRuntime) ?? "") ?? .ollama }
        set { d.set(newValue.rawValue, forKey: SettingsKeys.localRuntime) }
    }

    var localModel: String {
        get { d.string(forKey: SettingsKeys.localModel) ?? "" }
        set { d.set(newValue, forKey: SettingsKeys.localModel) }
    }

    var localCommandModel: String {
        get { d.string(forKey: SettingsKeys.localCommandModel) ?? "" }
        set { d.set(newValue, forKey: SettingsKeys.localCommandModel) }
    }

    // MARK: 花钱的两个开关（默认关）

    /// `service_tier:"fast"`：延迟更低更稳，token 单价约 2 倍。只有 OpenAI 认这个字段。
    /// 默认关——多花的钱必须是用户自己点下去的。
    var fastTier: Bool {
        get { d.bool(forKey: SettingsKeys.fastTier) }
        set { d.set(newValue, forKey: SettingsKeys.fastTier) }
    }

    /// 指令模式（按住）允许模型联网搜索。**只作用于指令**：润色是"改写我说的话"，
    /// 联网既没用又要花钱，那条路一个搜索参数都不发。默认关，$ 单价写在开关旁。
    var webSearchEnabled: Bool {
        get { d.bool(forKey: SettingsKeys.webSearchEnabled) }
        set { d.set(newValue, forKey: SettingsKeys.webSearchEnabled) }
    }

    /// 当前服务商的联网写法（各家形状不同，对外只有一个开关）
    var webSearchStyle: LLMCatalog.WebSearchStyle {
        LLMCatalog.searchStyle(provider: llmProvider, baseURL: currentBaseURL)
    }

    var openaiCommandModel: String {
        get { d.string(forKey: SettingsKeys.openaiCommandModel) ?? LLMCatalog.defaultModel(for: .openai) }
        set { d.set(newValue, forKey: SettingsKeys.openaiCommandModel) }
    }

    var deepseekCommandModel: String {
        get { d.string(forKey: SettingsKeys.deepseekCommandModel) ?? LLMCatalog.defaultModel(for: .deepseek) }
        set { d.set(newValue, forKey: SettingsKeys.deepseekCommandModel) }
    }

    /// 润色温度（低=稳定保真）；指令温度（1.0 = 模型默认，最自然）
    var polishTemperature: Double {
        get { d.object(forKey: SettingsKeys.polishTemperature) as? Double ?? 0.5 }
        set { d.set(newValue, forKey: SettingsKeys.polishTemperature) }
    }
    var commandTemperature: Double {
        get { d.object(forKey: SettingsKeys.commandTemperature) as? Double ?? 1.0 }
        set { d.set(newValue, forKey: SettingsKeys.commandTemperature) }
    }

    /// 「关于我」：署名、惯用语气等，注入语音指令 prompt
    var aboutMe: String {
        get { d.string(forKey: SettingsKeys.aboutMe) ?? "" }
        set { d.set(newValue, forKey: SettingsKeys.aboutMe) }
    }

    /// **某一档**服务商的 Base URL——不能只有"当前生效那档"。
    /// 为什么：粘贴即验证要把候选 Key 发到用户**刚选中**的那一档去（引导第 5 屏选了 DeepSeek 时，
    /// 生效档可能还是 OpenAI）。读全局当前档就等于把一家的 Key 送到另一家的端点上，
    /// 而且那趟必然 401 → Key 存不进钥匙串 → 那一档永远采纳不了（见 KeyVerifier.Probe）。
    func baseURL(for provider: LLMProvider) -> String {
        switch provider {
        case .openai: return openaiBaseURL
        case .deepseek: return deepseekBaseURL
        // 可能是 ""（自定义端点还没填地址）：
        // 空地址由 LLMClient 当面报"地址还没填完"，绝不悄悄替用户换一个能连上的地址。
        case .qwen: return qwenBaseURL
        case .custom: return customBaseURL
        case .local: return localRuntime.baseURL
        }
    }

    /// 当前服务商生效的 Base URL / 润色模型（快）/ 指令模型（强）
    var currentBaseURL: String { baseURL(for: llmProvider) }
    var currentPolishModel: String {
        switch llmProvider {
        case .openai: return chatModel
        case .deepseek: return deepseekModel
        case .qwen: return qwenModel
        case .custom: return customModel
        case .local: return localModel
        }
    }
    var currentCommandModel: String {
        switch llmProvider {
        case .openai: return openaiCommandModel
        case .deepseek: return deepseekCommandModel
        case .qwen: return qwenCommandModel
        case .custom: return customCommandModel
        case .local: return localCommandModel
        }
    }

    /// 首启动引导是否已经走完。**只有两种情况会写真**：在最后一屏把三件必办的事都办完了，
    /// 或者用户点过「先跳过」。中途关窗口不算——关掉窗口的人多半正卡在某一步上，
    /// 下次启动要把他接回没走完的那一屏（见 AppDelegate.routeFirstLaunch）。
    var onboardingCompleted: Bool {
        get { d.bool(forKey: SettingsKeys.onboardingCompleted) }
        set { d.set(newValue, forKey: SettingsKeys.onboardingCompleted) }
    }

    /// 引导第一屏确认过快捷键。默认值（右 Option）也要他点一下「继续」才算数——
    /// 这一屏教的就是"按哪颗键"，没看过它的人后面每一句「轻点 XX」都无从照做。
    var hotkeyConfirmed: Bool {
        get { d.bool(forKey: SettingsKeys.hotkeyConfirmed) }
        set { d.set(newValue, forKey: SettingsKeys.hotkeyConfirmed) }
    }

    /// 用户带着没办完的事走出了引导（点过「先跳过」）。
    /// 它只管一件事：**别每次启动都再拦他一次**。缺的那几项照常在设置概览上挂着徽章，
    /// 办齐之后从引导点「完成」会把这一位清掉。
    var onboardingSkippedEssentials: Bool {
        get { d.bool(forKey: SettingsKeys.onboardingSkippedEssentials) }
        set { d.set(newValue, forKey: SettingsKeys.onboardingSkippedEssentials) }
    }

    /// Qwen 模型 HF 仓库 ID
    var qwenModelRepo: String {
        get { d.string(forKey: SettingsKeys.qwenModelRepo) ?? QwenModels.defaultRepo }
        set { d.set(newValue, forKey: SettingsKeys.qwenModelRepo) }
    }

    /// 识别语言（存的是 BCP-47 代码，"" = 自动检测，默认值）。
    /// 只有用户显式选过才不是 Auto——MicType 永远不按场景/历史替他切语言。
    var recognitionLanguage: String {
        get { d.string(forKey: SettingsKeys.recognitionLanguage) ?? RecognitionLanguages.autoCode }
        set { d.set(newValue, forKey: SettingsKeys.recognitionLanguage) }
    }

    /// 送给识别模型的语言参数：英文全名，或 nil（自动检测）。
    /// 脏值也回 nil，见 RecognitionLanguages.modelLanguage。
    var recognitionModelLanguage: String? {
        RecognitionLanguages.modelLanguage(for: recognitionLanguage)
    }

    // MARK: 识别引擎（本地 / 云端）

    /// 用哪个识别引擎。默认、且脏值一律回落 `.local`——**音频离不离开这台 Mac 只由用户决定**，
    /// 一条读不懂的设置绝不能把录音送上云端。
    var recognitionEngine: RecognitionEngineChoice {
        get { RecognitionEngineChoice.parse(d.string(forKey: SettingsKeys.recognitionEngine) ?? "") }
        set { d.set(newValue.rawValue, forKey: SettingsKeys.recognitionEngine) }
    }

    /// 云端·阿里云那一档用哪个模型。默认 qwen3-asr-flash：同步识别端点上只有它
    /// （4.0.0 默认的 qwen-audio-3.0-asr-flash 打这个端点必 404，见 AlibabaASRModel）。
    var cloudAlibabaModel: AlibabaASRModel {
        get { AlibabaASRModel(rawValue: d.string(forKey: SettingsKeys.cloudAlibabaModel) ?? "")
                ?? .qwen3Flash }
        set { d.set(newValue.rawValue, forKey: SettingsKeys.cloudAlibabaModel) }
    }

}
