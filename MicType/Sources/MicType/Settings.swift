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

    var displayName: String {
        switch self {
        case .rightOption: return tr("右 Option (⌥)", "Right Option (⌥)")
        case .rightCommand: return tr("右 Command (⌘)", "Right Command (⌘)")
        case .rightControl: return tr("右 Control (⌃)", "Right Control (⌃)")
        case .rightShift: return tr("右 Shift (⇧)", "Right Shift (⇧)")
        case .leftOption: return tr("左 Option (⌥)", "Left Option (⌥)")
        case .leftCommand: return tr("左 Command (⌘)", "Left Command (⌘)")
        case .leftControl: return tr("左 Control (⌃)", "Left Control (⌃)")
        case .fn: return tr("Fn / 🌐 地球键", "Fn / 🌐 Globe key")
        }
    }

    var shortSymbol: String {
        switch self {
        case .rightOption: return tr("右⌥", "R⌥")
        case .rightCommand: return tr("右⌘", "R⌘")
        case .rightControl: return tr("右⌃", "R⌃")
        case .rightShift: return tr("右⇧", "R⇧")
        case .leftOption: return tr("左⌥", "L⌥")
        case .leftCommand: return tr("左⌘", "L⌘")
        case .leftControl: return tr("左⌃", "L⌃")
        case .fn: return tr("Fn", "Fn")
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

// MARK: - 大模型服务商

enum LLMProvider: String, CaseIterable {
    case openai
    case deepseek

    var displayName: String {
        switch self {
        case .openai: return "OpenAI (GPT)"
        case .deepseek: return "DeepSeek"
        }
    }
    var keychainAccount: String {
        switch self {
        case .openai: return "openai_api_key"
        case .deepseek: return "deepseek_api_key"
        }
    }
    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com"
        }
    }
    var defaultModel: String {
        switch self {
        case .openai: return "gpt-5.4-mini"
        case .deepseek: return "deepseek-v4-flash"
        }
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
    static let fillerWords = "fillerWords"                 // 本地口水词过滤表（默认空 = 不过滤）
    static let playSounds = "playSounds"
    static let restoreClipboard = "restoreClipboard"
    static let autoStopSilenceSeconds = "autoStopSilenceSeconds"  // 静音自动停秒数（0 = 关）
    static let livePreview = "livePreview"                 // 录音中悬浮窗灰字预览（伪流式）
    static let qwenModelRepo = "qwenModelRepo"
    static let llmProvider = "llmProvider"
    static let appLanguage = "appLanguage"
    static let deepseekBaseURL = "deepseekBaseURL"
    static let deepseekModel = "deepseekModel"
    static let onboardingCompleted = "onboardingCompleted"  // 首启动引导是否走过（老用户按"已配置好"自动置真）
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
            SettingsKeys.chatModel: "gpt-5.5",
            SettingsKeys.openaiCommandModel: "gpt-5.4-mini",
            SettingsKeys.deepseekCommandModel: LLMProvider.deepseek.defaultModel,
            SettingsKeys.polishTemperature: 0.5,
            SettingsKeys.commandTemperature: 1.0,
            SettingsKeys.aboutMe: "",
            SettingsKeys.customPolishRules: "",
            SettingsKeys.customVocabulary: "",
            SettingsKeys.fillerWords: "",
            SettingsKeys.playSounds: true,
            SettingsKeys.restoreClipboard: true,
            SettingsKeys.autoStopSilenceSeconds: 0.0,
            SettingsKeys.livePreview: true,
            SettingsKeys.qwenModelRepo: QwenModels.defaultRepo,
            SettingsKeys.llmProvider: LLMProvider.openai.rawValue,
            SettingsKeys.deepseekBaseURL: LLMProvider.deepseek.defaultBaseURL,
            SettingsKeys.deepseekModel: LLMProvider.deepseek.defaultModel,
            SettingsKeys.onboardingCompleted: false,
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
        get { d.string(forKey: SettingsKeys.chatModel) ?? "gpt-5.5" }
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

    /// 词汇表解析：普通词条做热词/润色提示；"错写=正写"词条做硬替换（正写同时进热词）。
    /// 一个正写可以挂多个错写：「杰文|捷纹|结文=捷文」——同一个名字的各种听错法不必分行写。
    var vocabularyEntries: (terms: [String], replacements: [(wrong: String, right: String)]) {
        var terms: [String] = []
        var replacements: [(String, String)] = []
        let raw = customVocabulary
            .replacingOccurrences(of: "＝", with: "=")
            .replacingOccurrences(of: "｜", with: "|")
        for item in raw.components(separatedBy: CharacterSet(charactersIn: ",，、\n")) {
            let entry = item.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            let parts = entry.split(separator: "=", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                let right = parts[1]
                let wrongs = parts[0].split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
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

    var vocabularyTerms: [String] { vocabularyEntries.terms }
    var vocabularyReplacements: [(wrong: String, right: String)] { vocabularyEntries.replacements }

    /// 口水词表原文（逗号/换行分隔），默认空——不填就完全不过滤，绝不替用户决定哪些词该删
    var customFillerWords: String {
        get { d.string(forKey: SettingsKeys.fillerWords) ?? "" }
        set { d.set(newValue, forKey: SettingsKeys.fillerWords) }
    }

    /// 解析后的口水词列表，供本机过滤用
    var fillerWords: [String] {
        customFillerWords
            .components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

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

    /// 录音中在悬浮窗显示灰色的实时草稿（伪流式预览）。默认开。
    /// 这条只影响"看得见"，永远不影响插入的文字——草稿绝不会进目标应用，
    /// 最终结果永远是松手后重跑的那一遍完整识别。
    var livePreview: Bool {
        get { d.bool(forKey: SettingsKeys.livePreview) }
        set { d.set(newValue, forKey: SettingsKeys.livePreview) }
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
        get { d.string(forKey: SettingsKeys.deepseekModel) ?? LLMProvider.deepseek.defaultModel }
        set { d.set(newValue, forKey: SettingsKeys.deepseekModel) }
    }

    var openaiCommandModel: String {
        get { d.string(forKey: SettingsKeys.openaiCommandModel) ?? "gpt-5.4-mini" }
        set { d.set(newValue, forKey: SettingsKeys.openaiCommandModel) }
    }

    var deepseekCommandModel: String {
        get { d.string(forKey: SettingsKeys.deepseekCommandModel) ?? LLMProvider.deepseek.defaultModel }
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

    /// 当前服务商生效的 Base URL / 润色模型（快）/ 指令模型（强）
    var currentBaseURL: String {
        switch llmProvider {
        case .openai: return openaiBaseURL
        case .deepseek: return deepseekBaseURL
        }
    }
    var currentPolishModel: String {
        switch llmProvider {
        case .openai: return chatModel
        case .deepseek: return deepseekModel
        }
    }
    var currentCommandModel: String {
        switch llmProvider {
        case .openai: return openaiCommandModel
        case .deepseek: return deepseekCommandModel
        }
    }

    /// 首启动引导是否已经走过（或被用户关掉）。为假时启动会自动弹引导。
    var onboardingCompleted: Bool {
        get { d.bool(forKey: SettingsKeys.onboardingCompleted) }
        set { d.set(newValue, forKey: SettingsKeys.onboardingCompleted) }
    }

    /// Qwen 模型 HF 仓库 ID
    var qwenModelRepo: String {
        get { d.string(forKey: SettingsKeys.qwenModelRepo) ?? QwenModels.defaultRepo }
        set { d.set(newValue, forKey: SettingsKeys.qwenModelRepo) }
    }

}
