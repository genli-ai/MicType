import Foundation

// MARK: - 热键选项

enum HotkeyChoice: String, CaseIterable {
    case rightOption
    case rightCommand
    case rightControl

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }

    var flagMask: UInt {
        switch self {
        case .rightOption: return 1 << 19   // NSEvent.ModifierFlags.option
        case .rightCommand: return 1 << 20  // NSEvent.ModifierFlags.command
        case .rightControl: return 1 << 18  // NSEvent.ModifierFlags.control
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: return tr("右 Option (⌥)", "Right Option (⌥)")
        case .rightCommand: return tr("右 Command (⌘)", "Right Command (⌘)")
        case .rightControl: return tr("右 Control (⌃)", "Right Control (⌃)")
        }
    }

    var shortSymbol: String {
        switch self {
        case .rightOption: return tr("右⌥", "R⌥")
        case .rightCommand: return tr("右⌘", "R⌘")
        case .rightControl: return tr("右⌃", "R⌃")
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
    static let playSounds = "playSounds"
    static let restoreClipboard = "restoreClipboard"
    static let qwenModelRepo = "qwenModelRepo"
    static let llmProvider = "llmProvider"
    static let appLanguage = "appLanguage"
    static let deepseekBaseURL = "deepseekBaseURL"
    static let deepseekModel = "deepseekModel"
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
            SettingsKeys.playSounds: true,
            SettingsKeys.restoreClipboard: true,
            SettingsKeys.qwenModelRepo: QwenModels.defaultRepo,
            SettingsKeys.llmProvider: LLMProvider.openai.rawValue,
            SettingsKeys.deepseekBaseURL: LLMProvider.deepseek.defaultBaseURL,
            SettingsKeys.deepseekModel: LLMProvider.deepseek.defaultModel,
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

    /// 词汇表解析：普通词条做热词/润色提示；"错写=正写"词条做硬替换（正写同时进热词）
    var vocabularyEntries: (terms: [String], replacements: [(wrong: String, right: String)]) {
        var terms: [String] = []
        var replacements: [(String, String)] = []
        let raw = customVocabulary.replacingOccurrences(of: "＝", with: "=")
        for item in raw.components(separatedBy: CharacterSet(charactersIn: ",，、\n")) {
            let entry = item.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            let parts = entry.split(separator: "=", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                replacements.append((parts[0], parts[1]))
                terms.append(parts[1])
            } else {
                terms.append(entry)
            }
        }
        return (terms, replacements)
    }

    var vocabularyTerms: [String] { vocabularyEntries.terms }
    var vocabularyReplacements: [(wrong: String, right: String)] { vocabularyEntries.replacements }

    var playSounds: Bool {
        get { d.bool(forKey: SettingsKeys.playSounds) }
        set { d.set(newValue, forKey: SettingsKeys.playSounds) }
    }

    var restoreClipboard: Bool {
        get { d.bool(forKey: SettingsKeys.restoreClipboard) }
        set { d.set(newValue, forKey: SettingsKeys.restoreClipboard) }
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

    /// Qwen 模型 HF 仓库 ID
    var qwenModelRepo: String {
        get { d.string(forKey: SettingsKeys.qwenModelRepo) ?? QwenModels.defaultRepo }
        set { d.set(newValue, forKey: SettingsKeys.qwenModelRepo) }
    }

}
