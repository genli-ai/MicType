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

    // 界面上只有一颗键可选了（用户 2026-09-20 拍板，见 Settings.hotkey）：4.1.0 之前这里
    // 还有一张 `offered` 表，摆着右侧三颗让人挑。枚举本身**不许砍**——HotkeyManager 那套
    // 按下/松开沿的判据是按 HotkeyChoice 写的，砍到只剩一个 case 等于把那层逻辑焊死，
    // 以后想加第二颗键得重写；而且老设置里存着别的值，读进来时仍要有对应的 case 认得它。

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

}

// 「润色档位」5.0.0 起不存在了（PolishLevel 连同菜单栏那个子菜单一起删）：
// 识别本身已经在云端跑，那把 Key 一定在，「仅识别、完全不联网」这一档已经没有意义。
// 润色从此永远开着——它是这个产品的一半，而不是一个要用户去发现的开关。
// 老设置里的 polishLevel 键读到就忽略（见 LegacyKeys）。

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

/// 5.0.0 起只有两家（用户 2026-09-22 拍板）；**5.1.0 起只剩 OpenAI**（用户 2026-09-28 拍板，
/// 与 iOS L36 同一个决定：用户少做一个决定——一家服务商、一把 Key）。阿里云那一档
/// （`qwen`）连同它的 Key、接入地址、区域等设置由启动时的 RetiredProviderCleanup 一次清掉。
///
/// 仍然留成枚举：Key 的钥匙串账号、Base URL、默认型号全按"这一档"取值，
/// 而"Key 永不串槽"那条铁律要求每把 Key 的存 / 读 / 删都点名 `provider.keychainAccount`。
/// DeepSeek / 自定义端点 / 本机大模型那三档（5.0.0 删掉）的钥匙串条目照旧**留着不删**。
enum LLMProvider: String, CaseIterable {
    case openai

    /// 用户认得的名字
    var displayName: String { "OpenAI (GPT)" }

    /// 短名（状态行、日志）
    var segmentName: String { "OpenAI" }

    /// 这一档的钥匙串条目。**名字一个字都不改**——老用户钥匙串里存的就是这一条。
    var keychainAccount: String { "openai_api_key" }

    /// 要 Key。留着这个属性是因为 KeyEntryView 与 LLMClient.credential 按它判"有没有 Key 可验"，
    /// 而 5.0.0 之前「本机模型」那一档是可以不填 Key 的。
    var requiresAPIKey: Bool { true }

    var defaultBaseURL: String { "https://api.openai.com/v1" }
}

// MARK: - AI 配置（5.0.0 起只剩「哪家在用 + 有没有 Key」）

/// 5.0.0 砍掉了「使用方式」（只用本地 / 本地 + AI）与「识别也用云端」两个决定：
/// 识别本来就只有云端一条路，润色永远开着，所以这两个开关问的都是一个没有第二个答案的问题。
/// 5.1.0 又删掉了最后那一条判断（adoptsProvider：看着的那一档能不能被采纳为生效服务商）——
/// 只剩 OpenAI 一家，没有第二档可采纳。
enum AISetup {

    // MARK: - 4.1.1：合并「关于我」到「自定义规则」

    /// 把「关于我」并进「自定义规则」。返回合并后的规则；nil = 什么都不用改。
    ///
    /// 为什么要合并（用户 2026-09-20 拍板）：两个多行框摆在一起，谁也说不清哪句话该写在哪个框里
    /// ——而它们最后都被拼进同一段提示词。合并之后界面上只有一个框、只在这一页出现一次。
    ///
    /// **只并一次**：规则里已经逐字含着那段「关于我」时不再重复（用户可能已经自己抄过去了）。
    /// 纯函数，单测钉死：这一步会改用户亲手写的文字，搬丢了他没有第二份。
    static func mergedRules(aboutMe: String, rules: String) -> String? {
        let about = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !about.isEmpty else { return nil }
        let existing = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        // 已经逐字含着这段话了：不再重复一遍（清空「关于我」那一步由调用方照做）
        guard !existing.contains(about) else { return nil }
        guard !existing.isEmpty else { return about }
        // 「关于我」排在前面：它讲的是"我是谁"，规则讲的是"怎么写"，读起来也是这个顺序
        return about + "\n" + existing
    }

    // MARK: - 4.1.1：联网搜索默认开

    /// 联网搜索的默认值从"关"改成"开"（用户 2026-09-20 拍板：支持的服务商一律默认开）。
    /// **明确选过的人一个字都不动**：UserDefaults 里存着值 = 他自己拨过那个开关
    /// （拨开再拨回也算——那是一次明确的"我不要"）。没存过 = 一直是出厂默认，跟着新默认走。
    /// 纯函数：判错的后果是替用户点开一个按次计费的开关。
    static func webSearchAfterDefaultChange(stored: Bool?) -> Bool { stored ?? true }

    // 「优先处理」那一行 4.1.6 起不存在了（用户 2026-09-21 拍板）：showsPriorityToggle 一并删掉。
    // 延迟是语音输入的全部体验，而"要不要多付一倍 token 钱换低延迟"根本不是一个该摆到用户
    // 面前的问题——OpenAI 官方接口一律走 Fast（LLMClient.asksForFastTier），代价在
    // 关于 → 隐私 里说一次（PrivacyCopy.fastTier）。
    //
    // showsRulesNeedAINote 5.0.0 删掉：「只用本地」那一档没有了，自定义规则永远会被发出去。
}

// MARK: - 设置键

enum SettingsKeys {
    static let hotkey = "hotkey"
    static let openaiBaseURL = "openaiBaseURL"
    static let polishTemperature = "polishTemperature"     // 润色温度（默认 0.3，4.3.3 从 0.5 降下来）
    static let commandTemperature = "commandTemperature"   // 指令温度（默认 1.0 = 模型默认）
    static let aboutMe = "aboutMe"
    static let customPolishRules = "customPolishRules"
    static let customVocabulary = "customVocabulary"
    static let fillerWords = "fillerWords"                 // 额外的口水词（4.0.2 起界面上没有这一项，内置表自动生效）
    static let playSounds = "playSounds"
    static let restoreClipboard = "restoreClipboard"
    static let autoStopSilenceSeconds = "autoStopSilenceSeconds"  // 静音自动停秒数（0 = 关）
    static let inputDeviceUID = "inputDeviceUID"            // 指定麦克风的 CoreAudio UID（"" = 系统默认）
    static let livePreview = "livePreview"                 // 录音中悬浮窗灰字草稿：5.2.0 起不再读（灰字整段删了），键留着只为认得旧值
    static let overlayPosition = "overlayPosition"         // 悬浮窗在屏幕上的落点
    static let keepHistory = "keepHistory"                 // 是否把听写结果记进历史（默认开）
    static let llmProvider = "llmProvider"
    static let appLanguage = "appLanguage"
    // 阿里云那一档的六个键（识别模型 / 区域 / WorkspaceId / 接入地址 / 试通主机 / 已验证）
    // 5.1.0 删掉，键名进 LegacyKeys.retiredAlibaba，启动时由 RetiredProviderCleanup 清掉。
    // 4.1.6 删掉了 "fastTier"：Fast 档不再是一条设置（OpenAI 官方接口恒开，见
    // LLMClient.asksForFastTier）。键名也不留——SettingsBackup 的 Key.all 里本来就没有它，
    // 导入的文件里带一条 fastTier 会被当成未知键忽略并计数，**绝不会**把 Fast 关掉。
    static let onboardingCompleted = "onboardingCompleted"  // 首启动引导是否走过（老用户按"已配置好"自动置真）
    static let onboardingSkippedEssentials = "onboardingSkippedEssentials"  // 他点过「先跳过」：引导不再每次启动拦他
}

// MARK: - 5.0.0 删掉的那些设置键

/// 这些键在 4.x 里是真设置，5.0.0 之后**一个都不读、也一个都不写**。
///
/// 为什么还要把名字留在代码里：设置导入（SettingsBackup）收到的文件多半是 4.x 导出的，
/// 里面每一条都在。不认得它们的话，导入摘要会报一串「未知键」，用户以为自己的文件坏了；
/// 而**认下来就当场忽略**是对的——那几件事（本机模型、识别语言、润色档位、云端识别开关、
/// 模型型号、DeepSeek / 自定义端点 / 本机大模型三档）在 5.0 里没有对应的东西可写。
///
/// 三条纪律：
///   • 只作忽略用，**绝不迁移**（没有目的地）；
///   • **绝不删 UserDefaults 里的值**（用户降级回 4.x 还要用它们）；
///   • 钥匙串里 DeepSeek / 自定义 / 本机那几把 Key 同理，一把都不删（那是用户自己的东西）。
///
/// **唯一的例外是 `retiredAlibaba` 那一组**（用户 2026-09-28 拍板）：5.1.0 删阿里云时
/// 明确要求把它的设置与 Key 一起清掉（见 RetiredProviderCleanup）。它们同样列进 `all`，
/// 好让 5.0 导出的设置文件导进来时不被报成"未知键"。
enum LegacyKeys {
    /// 5.1.0 删掉的阿里云那一档留在 UserDefaults 里的键（含三条已无意义的一次性迁移标记）
    static let retiredAlibaba: Set<String> = [
        "cloudAlibabaModel", "qwenRegion", "qwenWorkspaceID", "qwenAPIHost",
        "qwenResolvedHost", "qwenHostVerified", "qwenFastestHostProbedAt", "qwenFastestHostProbeVersion",
        "migratedQwenLegacyHost", "migratedQwenHostVerified", "migratedCloudASRModelTo3",
    ]

    static let all: Set<String> = retiredAlibaba.union([
        // 润色档位 / 开关
        "polishLevel", "polishEnabled",
        // 本机识别模型与它那一整套目录 / 升级 / 清理状态
        "qwenModelRepo", "modelCatalogLastCheck", "modelCatalogRetryAfter",
        "pendingModelCleanup", "pendingModelCleanupLaunch", "pendingModelCleanupSucceeded",
        "appLaunchCount", "dismissedModelUpgradeRepo",
        // 识别语言（两家云端都不发语言提示）与识别引擎（永远云端）
        "recognitionLanguage", "recognitionEngine", "cloudRecognitionWanted",
        // 麦克风选择（跟随系统默认）
        "inputDeviceUID",
        // 型号：5.0 起写死平衡档（LLMCatalog.polishDefault / commandDefault）
        "chatModel", "openaiCommandModel", "qwenModel", "qwenCommandModel",
        "deepseekModel", "deepseekCommandModel", "customModel", "customCommandModel",
        "localModel", "localCommandModel", "modelMigrationNotice",
        // 删掉的那三档服务商自己的配置
        "deepseekBaseURL", "customBaseURL", "localRuntime",
        // 联网搜索：支持的服务商永远开
        "webSearchEnabled",
    ])

    /// 这个键是 5.0 之前的遗留吗（前缀那一条是「这份模型文件我点过以后再说」，按仓库一条）
    static func isLegacy(_ key: String) -> Bool {
        all.contains(key) || key.hasPrefix("dismissedModelRefresh_")
    }
}

// MARK: - 设置

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            SettingsKeys.hotkey: HotkeyChoice.rightOption.rawValue,
            SettingsKeys.openaiBaseURL: "https://api.openai.com/v1",
            SettingsKeys.polishTemperature: Settings.defaultPolishTemperature,
            SettingsKeys.commandTemperature: 1.0,
            SettingsKeys.aboutMe: "",
            SettingsKeys.customPolishRules: "",
            SettingsKeys.customVocabulary: "",
            SettingsKeys.fillerWords: "",
            SettingsKeys.playSounds: true,
            SettingsKeys.restoreClipboard: true,
            SettingsKeys.autoStopSilenceSeconds: 0.0,
            // 5.2.0 起没人读它了（草稿改成悬浮窗上的字数，开关删掉）；默认值留着只为旧值读起来一致
            SettingsKeys.livePreview: false,
            SettingsKeys.overlayPosition: OverlayPosition.bottomCenter.rawValue,
            SettingsKeys.keepHistory: true,
            SettingsKeys.llmProvider: LLMProvider.openai.rawValue,
            SettingsKeys.onboardingCompleted: false,
            SettingsKeys.onboardingSkippedEssentials: false,
        ])

        // 一次性迁移：产品由 VoiceFlow 改名 MicType，defaults 域随 Bundle ID 变更，
        // 把旧域里用户设置过的值（词汇表、Base URL 等）原样搬过来。
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

        // 4.x 那一长串型号迁移（migratedModelToMini2 / migratedSplitModels / migratedPolishTo55 /
        // migrationTo56 / migrationToBestDefault / migrationToFastDefault）5.0.0 起**全部删掉**：
        // 型号不再是一条设置（写死平衡档，见 LLMCatalog.polishDefault），没有东西可迁。
        // 存着的那些型号键留在 UserDefaults 里不动（见 LegacyKeys 的三条纪律）。

        // 阿里云那三条一次性迁移（4.0.1 老区域 → 主机种子、4.1.1 "已验证"标记、
        // 4.0.1 识别模型 3.0 → qwen3）5.1.0 随阿里云一起删掉；它们的标记键由
        // RetiredProviderCleanup 清掉。那一档的删除本身**不在这里做**：它要动钥匙串，
        // 而 Settings.shared 在单测里也会被初始化——见 AppDelegate 启动时那一次调用。

        // 一次性迁移（4.1.0）：快捷键只剩右 Option 一颗（用户 2026-09-20 拍板）。
        // 界面上从此没有任何地方改得动它，所以老设置里存着的左 Command / Fn 会变成
        // 一颗**改不掉的坏键**：他按右 Option 没反应，而设置页上白纸黑字写着「右 Option (⌥)」。
        if !d.bool(forKey: "migratedHotkeyToRightOption") {
            let stored = d.string(forKey: SettingsKeys.hotkey) ?? ""
            if stored != HotkeyChoice.rightOption.rawValue {
                Log.info("Hotkey migrated to=rightOption from=\(stored.isEmpty ? "unset" : stored)")
                d.set(HotkeyChoice.rightOption.rawValue, forKey: SettingsKeys.hotkey)
            }
            d.set(true, forKey: "migratedHotkeyToRightOption")
        }

        // 一次性迁移（4.1.1）：「关于我」并进「自定义规则」（用户 2026-09-20 拍板）。
        // 界面上从此只有一个框，「关于我」那个键只留给设置文件的兼容——不搬的话，
        // 老用户亲手写的那段话会在这一版之后彻底失效，而界面上一个字都不会提。
        if !d.bool(forKey: "migratedAboutMeIntoRules") {
            normalizePersonalFields()
            d.set(true, forKey: "migratedAboutMeIntoRules")
        }

        // 一次性迁移（5.0.0）：服务商只剩 OpenAI 与阿里云（5.1.0 起只剩 OpenAI，见 RetiredProviderCleanup）。
        //
        // 存着 deepseek / custom / local 的人，llmProvider 读出来会退回 OpenAI（枚举没有
        // 那几个 case 了），而他的 OpenAI 档很可能一把 Key 都没有——那等于**静默**把他
        // 变成一个不能用的配置。所以这里把这件事记下来并**落盘**，AppDelegate 据此弹引导
        // （他自己的 DeepSeek Key 留在钥匙串里，一个字都不动）。
        if !d.bool(forKey: "migratedProvidersToTwo") {
            let stored = d.string(forKey: SettingsKeys.llmProvider) ?? ""
            // qwen 不在这里改：它归 RetiredProviderCleanup（5.1.0），那边要据此判断
            // "这位是阿里云用户"、记那行迁移日志——在这里先改成 openai 就把线索抹了
            if LLMProvider(rawValue: stored) == nil,
               stored != RetiredProviderCleanup.retiredProviderRawValue {
                Log.info("LLM provider dropped in 5.0 from=\(stored.isEmpty ? "unset" : stored) "
                         + "— falling back to openai")
                d.set(LLMProvider.openai.rawValue, forKey: SettingsKeys.llmProvider)
            }
            d.set(true, forKey: "migratedProvidersToTwo")
        }
    }


    /// 「关于我」→「自定义规则」的合并（迁移与设置导入共用这一份）。
    /// 导入也要走：别人给的设置文件里仍然带着 aboutMe，收下之后界面上没有任何地方显示它。
    func normalizePersonalFields() {
        let about = d.string(forKey: SettingsKeys.aboutMe) ?? ""
        guard !about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let merged = AISetup.mergedRules(aboutMe: about,
                                            rules: d.string(forKey: SettingsKeys.customPolishRules) ?? "") {
            d.set(merged, forKey: SettingsKeys.customPolishRules)
        }
        d.set("", forKey: SettingsKeys.aboutMe)
        // 内容本身绝不进日志（那是用户写给 AI 的私人偏好），只记发生过这件事
        Log.info("About-me merged into custom rules")
    }

    // normalizeModelPair 5.0.0 删掉：型号不再是设置，没有"两个字段对不上"这回事了。

    /// 听写快捷键。**永远是右 Option**（用户 2026-09-20 拍板：只留这一个选择）。
    ///
    /// 为什么写死而不是留个选择器：这颗键是产品的第一句话——引导、菜单栏、悬浮窗、
    /// 出错提示里每一句操作说明都要念出它的名字。摆出三颗让人挑，等于在他还没用过一次
    /// 听写、没有任何依据的时刻先要他做一个决定，而选错的代价（左侧键误触、Fn 被系统抢走）
    /// 要到很久以后才显形。右 Option 日常几乎不单独用，是那三颗里唯一不需要先上一课的。
    ///
    /// 它仍然是 HotkeyChoice 而不是常量：HotkeyManager 整层按枚举工作，这里只是没有
    /// 第二个值进得来（存着别的值的老设置由上面那条迁移改掉）。
    var hotkey: HotkeyChoice { .rightOption }

    var openaiBaseURL: String {
        get {
            // 被清空保存过也回退默认——Base URL 永远自动有值，用户只在自定义网关时才需要改
            let v = d.string(forKey: SettingsKeys.openaiBaseURL)?.trimmingCharacters(in: .whitespaces) ?? ""
            return v.isEmpty ? "https://api.openai.com/v1" : v
        }
        set { d.set(newValue, forKey: SettingsKeys.openaiBaseURL) }
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

    /// 5.0.0 起**永远跟随系统默认麦克风**（用户 2026-09-22 拍板：设置页只做一个决定）。
    /// 界面上没有麦克风选择器了，这个属性留着只为一件事：AudioRecorder 那一层还按
    ///「指定了就用指定的」工作，而它对空串就是"跟随系统默认"。
    var inputDeviceUID: String { "" }

    // livePreview（录音中的灰字草稿）5.2.0 删掉：悬浮窗改成右端一个「N 字」计数
    // （UX 方案 §3 C，用户 2026-09-29 拍板），开关随之删掉。存储键留着（SettingsKeys.livePreview），
    // 导入旧的设置文件时只认不写（SettingsBackup.Key.legacyIgnored）。

    /// 悬浮窗落点。只影响"出现在哪"，不影响任何行为；多屏仍然永远跟随鼠标所在那块屏。
    /// 读不出/读到脏值一律回退底部居中——位置这种东西绝不能因为一条坏设置就丢到屏幕外。
    var overlayPosition: OverlayPosition {
        get { OverlayPosition(rawValue: d.string(forKey: SettingsKeys.overlayPosition) ?? "") ?? .bottomCenter }
        set { d.set(newValue.rawValue, forKey: SettingsKeys.overlayPosition) }
    }

    /// 是否把每次听写/指令的结果记进历史（5.0.5 起是 Logs/MicType/Transcripts 下按天的纯文本）。
    /// 默认开——历史是菜单栏的一级功能。关掉后立即停止写入，已有的记录留着，
    /// 要清由用户自己点「清空记录」或在历史窗口里逐条删：这类事永远不替他做主。
    var keepHistory: Bool {
        get { d.bool(forKey: SettingsKeys.keepHistory) }
        set { d.set(newValue, forKey: SettingsKeys.keepHistory) }
    }

    /// 识别 + 润色 + 指令三件事共用的这一家。**5.1.0 起永远是 OpenAI**：
    /// 存着任何别的值（5.0 之前那三档、5.0.x 的 qwen）的老设置读出来都是 OpenAI——
    /// qwen 那一档由启动时的 RetiredProviderCleanup 改写并记一行日志。
    var llmProvider: LLMProvider {
        get { LLMProvider(rawValue: d.string(forKey: SettingsKeys.llmProvider) ?? "") ?? .openai }
        set { d.set(newValue.rawValue, forKey: SettingsKeys.llmProvider) }
    }

    // MARK: 联网搜索（5.0.0 起永远开，没有开关）

    /// 指令模式（按住）允许模型联网搜索。**只作用于指令**：润色是"改写我说的话"，
    /// 联网既没用又要花钱，那条路一个搜索参数都不发。
    ///
    /// 5.0.0 把这条设置删了（用户 2026-09-22 拍板）：指令里"查一下…""最新的…"是常态，
    /// 关着的结果是模型一本正经地编，而用户既看不出它没联网、也不知道有这么个开关——
    /// 那不是一个该摆到他面前的问题。支持的服务商永远开，代价在 关于 → 隐私 里说一次。
    /// 不支持的那一档（webSearchStyle == .none）自然什么都不发。
    var webSearchEnabled: Bool { true }

    /// 当前服务商的联网写法（各家形状不同，对外一个开关都没有）
    var webSearchStyle: LLMCatalog.WebSearchStyle {
        LLMCatalog.searchStyle(provider: llmProvider, baseURL: currentBaseURL)
    }

    /// 润色温度的默认值。**4.3.3 从 0.5 降到 0.3**：温度越低模型越少自由发挥（少无中生有的
    /// 编号列表、少改写措辞），保真校验（polishDriftCheck）的误拦就跟着少——而误拦的代价是
    /// 用户拿到一整段没润色过的识别原文。4.3.3 的真 Key 实测：0.2 与 0.5 对满是语气词的
    /// 口述都是 0 残留，清理质量没差别，0.2 还略快一点。界面上没有这一项（不要温度滑杆），
    /// 只有导入设置文件能改；**已经存过值的用户不迁移**，那是他自己填进来的数。
    static let defaultPolishTemperature: Double = 0.3

    /// 润色温度（低=稳定保真）；指令温度（1.0 = 模型默认，最自然）
    var polishTemperature: Double {
        get { d.object(forKey: SettingsKeys.polishTemperature) as? Double ?? Settings.defaultPolishTemperature }
        set { d.set(newValue, forKey: SettingsKeys.polishTemperature) }
    }
    var commandTemperature: Double {
        get { d.object(forKey: SettingsKeys.commandTemperature) as? Double ?? 1.0 }
        set { d.set(newValue, forKey: SettingsKeys.commandTemperature) }
    }

    /// 「关于我」。**4.1.1 起界面上没有这个框了**，内容已经并进「自定义规则」
    /// （AISetup.mergedRules），提示词那一侧也只读合并后的那一个字段。
    /// 这个键只为设置文件留着：别人给的文件（以及 Windows 端）里仍然可能带着它，
    /// 收下之后由 normalizePersonalFields 并进规则，绝不静默丢掉用户写过的字。
    var aboutMe: String {
        get { d.string(forKey: SettingsKeys.aboutMe) ?? "" }
        set { d.set(newValue, forKey: SettingsKeys.aboutMe) }
    }

    /// **某一档**服务商的 Base URL。5.1.0 起只有 OpenAI 一档；参数留着，
    /// 调用方继续点名"发给哪一档"（Key 永不串槽那条铁律按档说话）。
    func baseURL(for provider: LLMProvider) -> String { openaiBaseURL }

    /// 当前服务商生效的 Base URL。
    var currentBaseURL: String { baseURL(for: llmProvider) }

    /// 润色与指令的型号**是写死的**（5.0.0 起，用户 2026-09-22 拍板）。
    /// 4.x 里它是一条设置 + 一个下拉；而"挑型号"是一个用户没有依据、也不该被问的问题，
    /// 默认值本来就是实测挑出来的速度/质量平衡点（见 LLMCatalog.polishDefault 的注释）。
    /// 5.0.6 起两者不再是同一个：OpenAI 润色 terra、指令 luna。
    var currentPolishModel: String { LLMCatalog.polishDefault(for: llmProvider) }
    var currentCommandModel: String { LLMCatalog.commandDefault(for: llmProvider) }

    /// 首启动引导是否已经走完。**只有两种情况会写真**：在最后一屏把三件必办的事都办完了，
    /// 或者用户点过「先跳过」。中途关窗口不算——关掉窗口的人多半正卡在某一步上，
    /// 下次启动要把他接回没走完的那一屏（见 AppDelegate.routeFirstLaunch）。
    var onboardingCompleted: Bool {
        get { d.bool(forKey: SettingsKeys.onboardingCompleted) }
        set { d.set(newValue, forKey: SettingsKeys.onboardingCompleted) }
    }

    /// 用户带着没办完的事走出了引导（点过「先跳过」）。
    /// 它只管一件事：**别每次启动都再拦他一次**。缺的那几项照常在设置概览上挂着徽章，
    /// 办齐之后从引导点「完成」会把这一位清掉。
    var onboardingSkippedEssentials: Bool {
        get { d.bool(forKey: SettingsKeys.onboardingSkippedEssentials) }
        set { d.set(newValue, forKey: SettingsKeys.onboardingSkippedEssentials) }
    }

    // MARK: 识别引擎（5.0.0 起只有云端，跟着服务商走）

    /// 这一刻用哪一档云端识别。**它不是一条设置**：识别只有云端一条路，5.1.0 起也只有
    /// OpenAI 一家。4.x 的 recognitionEngine / cloudRecognitionWanted 两个键读到就忽略（见 LegacyKeys）。
    var recognitionEngine: RecognitionEngineChoice { .cloudOpenAI }

    /// 送给识别模型的语言参数。**永远是 nil**：OpenAI 那边自动检测本来就准。
    var recognitionModelLanguage: String? { nil }

}

// MARK: - 5.1.0：阿里云整档删除（启动时一次）

/// 老用户升上 5.1.0 的那一次清理（用户 2026-09-28 拍板，与 iOS L36 同一个决定）。
///
/// 三件事，**顺序无关、只做一次**（标记落盘）：
///   1. 生效服务商是 qwen → 改成 openai；
///   2. 钥匙串里阿里云的两条 Key（`qwen_api_key`，以及 4.0 开发期的旧名 `dashscope_api_key`）删掉；
///   3. 阿里云那一档留在 UserDefaults 里的键（LegacyKeys.retiredAlibaba）清掉。
///
/// **绝不把阿里云的 Key 当成 OpenAI 的 Key 用**：这里一个字节都不搬，只删。
/// 删完之后没有 OpenAI Key 的人，`RecognitionEngineReadiness` 是 `.cloudKeyMissing`、
/// aiStatus 是 `.off`，AppDelegate.routeFirstLaunch 会把他接回引导 ③（与 5.0 升级时
/// DeepSeek 用户走的是同一条路）。升级提示里**不提**阿里云被删——只记日志（用户不喜欢被打扰）。
///
/// 为什么不放在 Settings.init 里：要动钥匙串，而 Settings.shared 在单测里也会被初始化——
/// 那样跑一遍测试就会删掉开发机上的真 Key。钥匙串与 UserDefaults 都由调用方注入，单测用假的。
enum RetiredProviderCleanup {

    /// 一次性标记
    static let flagKey = "migratedRetiredAlibabaProvider"
    /// 老设置里阿里云那一档存的 llmProvider 原值
    static let retiredProviderRawValue = "qwen"
    /// 要删的钥匙串账号：现用名 + 4.0 开发期的旧名
    static let retiredKeychainAccounts = ["qwen_api_key", "dashscope_api_key"]

    struct Outcome: Equatable {
        /// 生效服务商原来是 qwen、这一次被改成了 openai
        let providerReset: Bool
        /// 清掉了几个 UserDefaults 键（只数真的存在的）
        let clearedDefaults: Int
    }

    /// - deleteKey: 删一条钥匙串条目（调用方传 KeychainHelper.deleteAPIKey）
    /// - Returns: nil = 以前已经做过，这次什么都没动
    @discardableResult
    static func run(defaults: UserDefaults, deleteKey: (String) -> Void) -> Outcome? {
        guard !defaults.bool(forKey: flagKey) else { return nil }
        let stored = defaults.string(forKey: SettingsKeys.llmProvider) ?? ""
        let providerReset = stored == retiredProviderRawValue
        if providerReset {
            defaults.set(LLMProvider.openai.rawValue, forKey: SettingsKeys.llmProvider)
        }
        var cleared = 0
        for key in LegacyKeys.retiredAlibaba where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            cleared += 1
        }
        // 删不删得掉都不重试：条目不存在时 SecItemDelete 回 errSecItemNotFound，那正是想要的结果
        for account in retiredKeychainAccounts { deleteKey(account) }
        defaults.set(true, forKey: flagKey)
        // 日志只有事件与计数，不含任何 Key 或主机名
        if providerReset {
            Log.info("Migration: Alibaba Cloud removed, provider reset to OpenAI")
        }
        Log.info("Migration: retired Alibaba Cloud settings cleared keys=\(cleared)")
        return Outcome(providerReset: providerReset, clearedDefaults: cleared)
    }
}
