import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - 设置导入导出（路线图 P21）
//
// 为什么做：词汇表与自定义规则是用户一天天攒出来的，换机 / 重装 / 在 Mac 和 Windows 之间
// 来回用的时候，这部分最不该重头再来。所以导出一个人能看懂、两端都能读的 JSON。
//
// 为什么**永远不导出 API Key**：Key 存在 macOS 钥匙串里（加密、仅本机可读），一旦写进明文文件，
// 用户随手把这个文件发给别人或塞进网盘，Key 就泄露了。导入端同理——只认下面这张表里的键，
// 文件里任何多余字段（包括手工塞进去的 apiKey）一律忽略，绝不往钥匙串写一个字。
//
// 导入是**合并**不是覆盖：词汇表 / 口水词取并集（老词条一条不少），标量设置只覆盖文件里出现的键。
// 这样「从旧机器导一份过来」不会把新机器上刚调好的东西抹掉。
//
// ---------------------------------------------------------------------------
// 文件格式（schemaVersion = 1，Windows 端照这张表读同一个文件即可）
//
// {
//   "schemaVersion": 1,
//   "app": "MicType",
//   "platform": "macOS",                      // 仅供人看
//   "exportedAt": "2026-09-19T08:00:00Z",     // 仅供人看
//   "settings": { ... }                       // 扁平表，值只有 string / number / bool 三种
// }
//
// settings 里的键（中立键名 → macOS UserDefaults 键 / Windows AppSettings 属性）：
//
//   hotkey                  ← hotkey                 / Hotkey
//                             字符串，取 macOS 的 rawValue：rightOption, rightCommand, rightControl,
//                             rightShift, leftOption, leftCommand, leftControl, fn。
//                             **macOS 4.1.0 起既不导出也不导入这一项**：Mac 上只剩右 Option 一颗键
//                             （见 Settings.hotkey），导入一个改不掉的键名只会让界面和实际监听对不上。
//                             键名仍留在已知键表里，好让从前导出的文件不被报成"忽略了 1 项"。
//   polishLevel             ← polishLevel            / PolishLevel          "off" | "smart"
//   vocabulary              ← customVocabulary       / CustomVocabulary     整段原文（逗号/换行分隔）
//   fillerWords             ← fillerWords            / FillerWords          整段原文（逗号/换行分隔）
//   aboutMe                 ← aboutMe                / AboutMe（4.1.1 起 Mac 侧只进不出：
//                             收下之后并进 customPolishRules，见 normalizePersonalFields）
//   customPolishRules       ← customPolishRules      / CustomPolishRules
//   llmProvider             ← llmProvider            / LlmProvider
//                             "openai" | "deepseek" | "qwen" | "custom" | "local"
//                             **切档要连它这一档的地址与型号一起带**：custom / local 出厂没有
//                             内置端点或型号名，只搬一个档位过去等于把对方的 AI 关掉（见下面几行）
//   openaiBaseURL           ← openaiBaseURL          / OpenAiBaseUrl
//                             只接受 https 且带主机名的地址，别的一律忽略（见 isAcceptableBaseURL）
//   deepseekBaseURL         ← deepseekBaseURL        / DeepSeekBaseUrl        同上
//   customBaseURL           ← customBaseURL          / （Windows 暂无）        同上
//   openaiPolishModel       ← chatModel              / OpenAiPolishModel
//   openaiCommandModel      ← openaiCommandModel     / OpenAiCommandModel
//   deepseekPolishModel     ← deepseekModel          / DeepSeekPolishModel
//   deepseekCommandModel    ← deepseekCommandModel   / DeepSeekCommandModel
//   qwenPolishModel         ← qwenModel              / （Windows 暂无）
//   qwenCommandModel        ← qwenCommandModel       / （Windows 暂无）
//   customPolishModel       ← customModel            / （Windows 暂无）
//   customCommandModel      ← customCommandModel     / （Windows 暂无）
//   localRuntime            ← localRuntime           / （Windows 暂无）        "ollama" | "lmstudio"
//   localPolishModel        ← localModel             / （Windows 暂无）
//   localCommandModel       ← localCommandModel      / （Windows 暂无）
//   polishTemperature       ← polishTemperature      / PolishTemperature    数字 0–1.5
//   commandTemperature      ← commandTemperature     / CommandTemperature   数字 0–1.5
//   appLanguage             ← appLanguage            / AppLanguage          "zh" | "en"
//   autoStopSilenceSeconds  ← autoStopSilenceSeconds / （Windows 暂无）      数字，0 = 关，否则 1–5
//   livePreview             ← livePreview            / （Windows 暂无）      布尔
//   playSounds              ← playSounds             / PlaySounds           布尔
//   restoreClipboard        ← restoreClipboard       / RestoreClipboard     布尔
//   keepHistory             ← keepHistory            / （Windows 暂无）      布尔
//   recognitionEngine       ← recognitionEngine      / （Windows 暂无）      "local" | "cloudAlibaba" | "cloudOpenAI"
//   recognitionLanguage     ← recognitionLanguage    / （Windows 暂无）      语言代码，"" = 自动检测
//   cloudAlibabaModel       ← cloudAlibabaModel      / （Windows 暂无）      "qwen3-asr-flash" | "qwen-audio-3.0-asr-flash"
//   qwenApiHost             ← qwenAPIHost            / （Windows 暂无）      百炼接入地址（4.1.4 起界面上没有这个框；空 = 自动探测）
//   qwenRegion              ← qwenRegion             / （Windows 暂无）      老设置：DashScope 接入区域（4.0.1 起界面上没有了）
//   qwenWorkspaceId         ← qwenWorkspaceID        / （Windows 暂无）      老设置：区域端点主机名第一段
//   speechModelRepo         ← qwenModelRepo          / （Windows 暂无）      HuggingFace 仓库 ID（"owner/name"）
//
// 关于 speechModelRepo：它确实和本机磁盘有关（导过去那台机器多半还没下这个模型），但它是
// **用户的选择**而不是下载状态——换机之后自己会在识别页看到"模型未下载"并下载。导出它是为了
// 「我用的是 1.7B 那一档」这件事别在换机时丢掉；下载进度、待删仓库这些状态仍然不进文件。
//
// 不进这个文件：API Key（安全）、模型下载状态（跟本机磁盘绑定）、登录启动（系统级注册）、
// 历史记录（另有 history.json）、引导是否走过（本机一次性状态）。
// ---------------------------------------------------------------------------

enum SettingsBackup {

    /// 当前格式版本。加字段不升版本（读取端忽略不认识的键即可），只有语义变了才 +1。
    static let schemaVersion = 1

    /// 文件里的中立键名（跟 macOS 的 UserDefaults 键故意不完全一样：两端都能对上才叫互通）
    enum Key {
        static let hotkey = "hotkey"
        static let polishLevel = "polishLevel"
        static let vocabulary = "vocabulary"
        static let fillerWords = "fillerWords"
        static let aboutMe = "aboutMe"
        static let customPolishRules = "customPolishRules"
        static let llmProvider = "llmProvider"
        static let openaiBaseURL = "openaiBaseURL"
        static let deepseekBaseURL = "deepseekBaseURL"
        static let customBaseURL = "customBaseURL"
        static let openaiPolishModel = "openaiPolishModel"
        static let openaiCommandModel = "openaiCommandModel"
        static let deepseekPolishModel = "deepseekPolishModel"
        static let deepseekCommandModel = "deepseekCommandModel"
        static let qwenPolishModel = "qwenPolishModel"
        static let qwenCommandModel = "qwenCommandModel"
        static let customPolishModel = "customPolishModel"
        static let customCommandModel = "customCommandModel"
        static let localRuntime = "localRuntime"
        static let localPolishModel = "localPolishModel"
        static let localCommandModel = "localCommandModel"
        static let polishTemperature = "polishTemperature"
        static let commandTemperature = "commandTemperature"
        static let appLanguage = "appLanguage"
        static let autoStopSilenceSeconds = "autoStopSilenceSeconds"
        static let livePreview = "livePreview"
        static let playSounds = "playSounds"
        static let restoreClipboard = "restoreClipboard"
        static let keepHistory = "keepHistory"
        static let recognitionEngine = "recognitionEngine"
        static let recognitionLanguage = "recognitionLanguage"
        static let cloudAlibabaModel = "cloudAlibabaModel"
        static let qwenApiHost = "qwenApiHost"
        static let qwenRegion = "qwenRegion"
        static let qwenWorkspaceId = "qwenWorkspaceId"
        static let speechModelRepo = "speechModelRepo"

        /// 已知键全集——不在这里面的一律忽略并计数（含任何伪装成设置的 Key 字段）
        static let all: Set<String> = [
            hotkey, polishLevel, vocabulary, fillerWords, aboutMe, customPolishRules,
            llmProvider, openaiBaseURL, deepseekBaseURL, customBaseURL,
            openaiPolishModel, openaiCommandModel, deepseekPolishModel, deepseekCommandModel,
            qwenPolishModel, qwenCommandModel, customPolishModel, customCommandModel,
            localRuntime, localPolishModel, localCommandModel,
            polishTemperature, commandTemperature, appLanguage,
            autoStopSilenceSeconds, livePreview, playSounds, restoreClipboard, keepHistory,
            recognitionEngine, recognitionLanguage, cloudAlibabaModel,
            qwenApiHost, qwenRegion, qwenWorkspaceId, speechModelRepo,
        ]
    }

    // MARK: - 导出

    /// 组装导出文档（纯函数，方便单测）
    static func makeDocument(date: Date = Date()) -> [String: Any] {
        let s = Settings.shared
        let settings: [String: Any] = [
            // Key.hotkey 不在这里：Mac 上快捷键只有一个值，导出它等于承诺对面能改
            Key.polishLevel: s.polishLevel.rawValue,
            Key.vocabulary: s.customVocabulary,
            Key.fillerWords: s.customFillerWords,
            // Key.aboutMe **不导出**（4.1.1 起只进不出）：这一版把「关于我」并进了自定义规则，
            // 迁移之后 Mac 这边它恒为空串。照写出去等于每份文件都带一条 `"aboutMe": ""`，
            // 而 Windows 端还有独立的「关于我」框——将来它做导入时，一条空串就把对方写的那段话抹了。
            // 内容本身不会丢：已经并进 customPolishRules 一起导出。
            Key.customPolishRules: s.customPolishRules,
            Key.llmProvider: s.llmProvider.rawValue,
            Key.openaiBaseURL: s.openaiBaseURL,
            Key.deepseekBaseURL: s.deepseekBaseURL,
            // custom / local 这两档的地址与型号必须一起导出：llmProvider 已经是五档了，
            // 只把档位搬过去、不带地址和型号名，对面就落到一个"端点空着、型号空着"的档上——
            // 轻点听写静默没了润色（custom 连凭据都判成没配），长按每次报"还没填模型名"。
            Key.customBaseURL: s.customBaseURL,
            Key.openaiPolishModel: s.chatModel,
            Key.openaiCommandModel: s.openaiCommandModel,
            Key.deepseekPolishModel: s.deepseekModel,
            Key.deepseekCommandModel: s.deepseekCommandModel,
            Key.qwenPolishModel: s.qwenModel,
            Key.qwenCommandModel: s.qwenCommandModel,
            Key.customPolishModel: s.customModel,
            Key.customCommandModel: s.customCommandModel,
            Key.localRuntime: s.localRuntime.rawValue,
            Key.localPolishModel: s.localModel,
            Key.localCommandModel: s.localCommandModel,
            Key.polishTemperature: s.polishTemperature,
            Key.commandTemperature: s.commandTemperature,
            Key.appLanguage: L10n.shared.language.rawValue,
            Key.autoStopSilenceSeconds: s.autoStopSilenceSeconds,
            Key.livePreview: s.livePreview,
            Key.playSounds: s.playSounds,
            Key.restoreClipboard: s.restoreClipboard,
            Key.keepHistory: s.keepHistory,
            // 识别这一段：引擎档位、语言、云端模型、接入地址、本机模型仓库。
            // Key 一如既往不在里面（云端识别用的就是「云端 AI」页那把 Key）。
            // 试出来的那台主机（qwenResolvedHost）**不导出**：它是本机探测的缓存，
            // 换台机器重新试一次就有，和模型下载状态同一类
            Key.recognitionEngine: s.recognitionEngine.rawValue,
            Key.recognitionLanguage: s.recognitionLanguage,
            Key.cloudAlibabaModel: s.cloudAlibabaModel.rawValue,
            Key.qwenApiHost: s.qwenAPIHost,
            Key.qwenRegion: s.qwenRegion.rawValue,
            Key.qwenWorkspaceId: s.qwenWorkspaceID,
            Key.speechModelRepo: s.qwenModelRepo,
        ]

        let stamp = ISO8601DateFormatter()
        stamp.timeZone = TimeZone(secondsFromGMT: 0)
        return [
            "schemaVersion": schemaVersion,
            "app": "MicType",
            "platform": "macOS",
            "exportedAt": stamp.string(from: date),
            "settings": settings,
        ]
    }

    /// 导出成人可读的 JSON（sortedKeys：同样的设置导出两次字节相同，方便 diff / 放进 git）
    static func exportData(date: Date = Date()) throws -> Data {
        try JSONSerialization.data(withJSONObject: makeDocument(date: date),
                                   options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - 导入

    struct ImportSummary {
        var vocabularyAdded = 0
        var vocabularySkipped = 0
        var fillerAdded = 0
        var fillerSkipped = 0
        var updatedKeys: [String] = []
        var ignoredKeys: [String] = []
        /// 需要当面点名的改动（接口地址 / 模型名）："键 = 新值"。
        /// 别的设置改错了顶多难用，这几项改错了是"换了个收信人"——只报数量等于没报。
        var notableChanges: [String] = []
        /// 文件来自更新版本的 MicType：能读的照读，读不懂的忽略，如实告诉用户
        var newerSchema = false
    }

    /// 合并一份「逗号/换行分隔」的列表：老词条原样保留，新词条追加在后面（并集，绝不删）。
    /// 判重按去空白后的整条精确比较——西文大小写不同的写法用户可能是故意的，不当重复。
    static func mergeList(existing: String, incoming: String)
        -> (merged: String, added: Int, skipped: Int) {
        // 分隔符与去空白都走 Settings 的同一套（含 \r）：备份文件本来就是 Mac/Windows 通用的，
        // 在这里漏掉 CR 的话，CRLF 条目会**带着裸 CR 被写进设置并持久化**，之后每次解析都带着它。
        func entries(_ text: String) -> [String] {
            Settings.parseList(text)
        }
        let have = Set(entries(existing))
        var seen = have
        var appended: [String] = []
        for entry in entries(incoming) where !seen.contains(entry) {
            seen.insert(entry)
            appended.append(entry)
        }
        let skipped = entries(incoming).count - appended.count

        guard !appended.isEmpty else { return (existing, 0, skipped) }
        var merged = existing
        if !merged.isEmpty && !merged.hasSuffix("\n") { merged += "\n" }
        merged += appended.joined(separator: "\n")
        return (merged, appended.count, skipped)
    }

    /// 导入进来的接口地址必须是 https 且带主机名，否则一律忽略。
    ///
    /// 为什么单独卡这一道：base URL 决定钥匙串里的 API Key 发给谁。一份"同事发来的 MicType 设置"
    /// 只要把 openaiBaseURL 换成自己的地址，用户下一次说话时 Key 和全部识别文本就一起送过去了——
    /// 而文件头还写着"不含 API Key"，最容易让人放心转发。
    /// 只认 https：明文 http 本来就会被 ATS 拦掉，放进去只是存了一个用不了的地址。
    static func isAcceptableBaseURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// 导入进来的识别语言必须是本版认得的代码（或 "" = 自动检测）。
    /// 认不出就忽略：脏代码会让本机引擎收到一句「language 某个乱码」，比没有语言设置更糟。
    static func isAcceptableRecognitionLanguage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return RecognitionLanguages.all.contains { $0.code == trimmed }
    }

    /// WorkspaceId 会被拼进**主机名第一段**（{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com），
    /// 所以这道闸和 base URL 那道是同一个理由：别人发来的文件不该能把你的音频指到别的主机去。
    /// 只放行主机名标签允许的字符。
    static func isAcceptableWorkspaceID(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }   // 空 = 不用专属主机，是合法状态
        guard trimmed.count <= 63 else { return false }
        return trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// 模型仓库 ID 只接受 "owner/name" 这种形状：它会被拼成本地目录名，也会被拿去拼下载地址。
    static func isAcceptableModelRepo(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128, !trimmed.contains("..") else { return false }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return trimmed.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/")
        }
    }

    /// 把文档应用到设置上（合并语义）。抛错只发生在「这压根不是一份 MicType 设置文件」。
    @discardableResult
    static func apply(document: [String: Any]) throws -> ImportSummary {
        guard let version = (document["schemaVersion"] as? NSNumber)?.intValue,
              let settings = document["settings"] as? [String: Any] else {
            throw MTError(tr("这不是 MicType 设置文件（缺少 schemaVersion / settings）",
                             "Not a MicType settings file (missing schemaVersion / settings)"))
        }

        var summary = ImportSummary()
        summary.newerSchema = version > schemaVersion

        // 1) 列表类：并集
        if let incoming = settings[Key.vocabulary] as? String {
            let r = mergeList(existing: Settings.shared.customVocabulary, incoming: incoming)
            Settings.shared.customVocabulary = r.merged
            summary.vocabularyAdded = r.added
            summary.vocabularySkipped = r.skipped
        } else if settings[Key.vocabulary] != nil {
            summary.ignoredKeys.append(Key.vocabulary)
        }

        if let incoming = settings[Key.fillerWords] as? String {
            let r = mergeList(existing: Settings.shared.customFillerWords, incoming: incoming)
            Settings.shared.customFillerWords = r.merged
            summary.fillerAdded = r.added
            summary.fillerSkipped = r.skipped
        } else if settings[Key.fillerWords] != nil {
            summary.ignoredKeys.append(Key.fillerWords)
        }

        // 2) 标量类：文件里出现才覆盖，没出现就一个字不动
        /// notable：接口 / 模型类的键，导入摘要里要按键名逐条念出新值
        func string(_ key: String, notable: Bool = false, _ assign: (String) -> Void) {
            guard let raw = settings[key] else { return }
            guard let value = raw as? String else { summary.ignoredKeys.append(key); return }
            assign(value)
            summary.updatedKeys.append(key)
            if notable { summary.notableChanges.append("\(key) = \(value)") }
        }
        /// 带校验的字符串：不合格就忽略并记一条。和 baseURL 那道闸同一个理由——
        /// 别人发来的文件不该能把你的音频、你的 Key 指到别处去。
        func checkedString(_ key: String, notable: Bool = false,
                           isValid: (String) -> Bool, _ assign: (String) -> Void) {
            guard let raw = settings[key] else { return }
            guard let value = raw as? String else { summary.ignoredKeys.append(key); return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValid(trimmed) else {
                summary.ignoredKeys.append(key)
                Log.warn("Settings import: rejected \(key) (failed validation)")
                return
            }
            assign(trimmed)
            summary.updatedKeys.append(key)
            if notable { summary.notableChanges.append("\(key) = \(trimmed)") }
        }
        /// 「这台机器没配这一档时天然就是空」的字段（自定义端点 / 本机模型的型号名）：
        /// **空值一律跳过**。导入是合并不是覆盖——导出方没用这一档而写出来的 ""，
        /// 不该把导入方已经填好的型号名抹掉；也不该记成一条"被忽略的键"（那是留给格式错误的）。
        func nonEmptyString(_ key: String, notable: Bool = false,
                            isValid: ((String) -> Bool)? = nil,
                            _ assign: (String) -> Void) {
            guard let raw = settings[key] else { return }
            guard let value = raw as? String else { summary.ignoredKeys.append(key); return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let isValid = isValid, !isValid(trimmed) {
                summary.ignoredKeys.append(key)
                Log.warn("Settings import: rejected \(key) (failed validation)")
                return
            }
            assign(trimmed)
            summary.updatedKeys.append(key)
            if notable { summary.notableChanges.append("\(key) = \(trimmed)") }
        }
        /// 接口地址：类型对还不够，还得是个我们敢把 Key 发过去的地址
        func baseURL(_ key: String, _ assign: (String) -> Void) {
            guard let raw = settings[key] else { return }
            guard let value = raw as? String, isAcceptableBaseURL(value) else {
                summary.ignoredKeys.append(key)
                Log.warn("Settings import: rejected \(key) (not an https URL)")
                return
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            assign(trimmed)
            summary.updatedKeys.append(key)
            summary.notableChanges.append("\(key) = \(trimmed)")
        }
        func number(_ key: String, range: ClosedRange<Double>, _ assign: (Double) -> Void) {
            guard let raw = settings[key] else { return }
            guard let value = (raw as? NSNumber)?.doubleValue else {
                summary.ignoredKeys.append(key); return
            }
            assign(min(max(value, range.lowerBound), range.upperBound))
            summary.updatedKeys.append(key)
        }
        func bool(_ key: String, _ assign: (Bool) -> Void) {
            guard let raw = settings[key] else { return }
            guard let value = raw as? Bool else { summary.ignoredKeys.append(key); return }
            assign(value)
            summary.updatedKeys.append(key)
        }
        /// 枚举一律大小写不敏感匹配——Windows 端写的是 PascalCase（RightControl / Smart / OpenAi）。
        /// notable：这一项决定"Key 和文本/音频发给谁、发到哪个区域"，必须在摘要里当面念出来
        /// （只报一句"其他设置：覆盖 12 项"等于把最该被看见的一条藏起来）。
        func enumValue<T: CaseIterable & RawRepresentable>(_ key: String, notable: Bool = false,
                                                           _ assign: (T) -> Void)
            where T.RawValue == String {
            guard let raw = settings[key] else { return }
            guard let text = raw as? String,
                  let match = T.allCases.first(where: { $0.rawValue.compare(text, options: .caseInsensitive) == .orderedSame }) else {
                summary.ignoredKeys.append(key)
                return
            }
            assign(match)
            summary.updatedKeys.append(key)
            if notable { summary.notableChanges.append("\(key) = \(match.rawValue)") }
        }

        // Key.hotkey 故意不导入：Mac 上快捷键永远是右 Option（见 Settings.hotkey）。
        // 它在 Key.all 里，所以老文件里的这一项不会被报成"不认识的键"，只是不起作用。
        enumValue(Key.polishLevel) { (v: PolishLevel) in Settings.shared.polishLevel = v }
        // 服务商换了 = 从此刻起 Key 和听写文本发给另一家。和识别引擎同一条纪律：当面念出来，
        // 只报一句"导入成功"等于把最该被看见的一条藏起来了。
        enumValue(Key.llmProvider, notable: true) { (v: LLMProvider) in Settings.shared.llmProvider = v }
        // 界面语言走 L10n（@Published，切了要立刻刷新界面；它自己负责落盘）
        enumValue(Key.appLanguage) { (v: AppLanguage) in L10n.shared.language = v }

        string(Key.aboutMe) { Settings.shared.aboutMe = $0 }
        string(Key.customPolishRules) { Settings.shared.customPolishRules = $0 }
        baseURL(Key.openaiBaseURL) { Settings.shared.openaiBaseURL = $0 }
        baseURL(Key.deepseekBaseURL) { Settings.shared.deepseekBaseURL = $0 }
        // 自定义端点的地址走同一道闸（https + 有主机名）：它决定钥匙串里的 Key 发给谁。
        // 空串先滤掉——那只是"导出方没用这一档"，不是一个坏地址，不该记进被忽略的键里。
        if let raw = settings[Key.customBaseURL] as? String,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            baseURL(Key.customBaseURL) { Settings.shared.customBaseURL = $0 }
        }
        string(Key.openaiPolishModel, notable: true) { Settings.shared.chatModel = $0 }
        string(Key.openaiCommandModel, notable: true) { Settings.shared.openaiCommandModel = $0 }
        string(Key.deepseekPolishModel, notable: true) { Settings.shared.deepseekModel = $0 }
        string(Key.deepseekCommandModel, notable: true) { Settings.shared.deepseekCommandModel = $0 }
        nonEmptyString(Key.qwenPolishModel, notable: true) { Settings.shared.qwenModel = $0 }
        nonEmptyString(Key.qwenCommandModel, notable: true) { Settings.shared.qwenCommandModel = $0 }
        nonEmptyString(Key.customPolishModel, notable: true) { Settings.shared.customModel = $0 }
        nonEmptyString(Key.customCommandModel, notable: true) { Settings.shared.customCommandModel = $0 }
        nonEmptyString(Key.localPolishModel, notable: true) { Settings.shared.localModel = $0 }
        nonEmptyString(Key.localCommandModel, notable: true) { Settings.shared.localCommandModel = $0 }
        enumValue(Key.localRuntime) { (v: LLMCatalog.LocalRuntime) in Settings.shared.localRuntime = v }

        number(Key.polishTemperature, range: 0...1.5) { Settings.shared.polishTemperature = $0 }
        number(Key.commandTemperature, range: 0...1.5) { Settings.shared.commandTemperature = $0 }
        // 0 = 关；其余落在设置界面允许的 1–5 秒内
        number(Key.autoStopSilenceSeconds, range: 0...5) {
            Settings.shared.autoStopSilenceSeconds = ($0 > 0 && $0 < 1) ? 1 : $0
        }

        // 识别引擎要当面念出来：这一项决定录音会不会离开这台 Mac，是整份文件里最该被看见的一条
        enumValue(Key.recognitionEngine, notable: true) { (v: RecognitionEngineChoice) in
            Settings.shared.recognitionEngine = v
        }
        // 这一项决定云端识别打的是哪个模型（也就是按什么价钱计费），和模型名同一条纪律
        enumValue(Key.cloudAlibabaModel, notable: true) { (v: AlibabaASRModel) in
            Settings.shared.cloudAlibabaModel = v
        }
        // 接入地址 = 收信主机，也就是 Key 与音频落在哪个司法辖区。一个字段就能把它们
        // 从新加坡搬到北京，所以必须当面念出来，而且只接受一个像样的主机名。
        // 空值一律跳过（nonEmptyString 而不是 checkedString）：4.0.1 的常态就是空着
        // （地址自己试出来），而导出端总是写出这个键。照 checkedString 收的话，导入任何一份
        // 没用过百炼的设置文件，都会抹掉导入方已经探测成功的主机缓存，还会在摘要里
        // 记一条空的 notable，触发那句"这份文件改了接入地址"的假警报。
        nonEmptyString(Key.qwenApiHost, notable: true,
                       isValid: { AlibabaEndpoint.normalizeHost($0) != nil }) {
            Settings.shared.qwenAPIHost = $0
            // 地址被文件改了，上一次试通的那台就不再算数（"验证过"那一位一起清）
            Settings.shared.qwenResolvedHost = ""
            Settings.shared.qwenHostVerified = false
        }
        // 老设置，界面上已经没有了（4.0.1 拿掉了区域选择器）。仍然接受它：它是候选
        // 主机表的排序线索，老文件导进来不该整段丢掉。
        enumValue(Key.qwenRegion, notable: true) { (v: LLMCatalog.QwenRegion) in
            Settings.shared.qwenRegion = v
        }
        checkedString(Key.recognitionLanguage, isValid: isAcceptableRecognitionLanguage) {
            Settings.shared.recognitionLanguage = $0
        }
        checkedString(Key.qwenWorkspaceId, notable: true, isValid: isAcceptableWorkspaceID) {
            Settings.shared.qwenWorkspaceID = $0
        }
        checkedString(Key.speechModelRepo, notable: true, isValid: isAcceptableModelRepo) {
            Settings.shared.qwenModelRepo = $0
        }

        bool(Key.livePreview) { Settings.shared.livePreview = $0 }
        bool(Key.playSounds) { Settings.shared.playSounds = $0 }
        bool(Key.restoreClipboard) { Settings.shared.restoreClipboard = $0 }
        // 这条走的是"要不要记录"这个偏好，历史内容本身照旧不进备份文件
        bool(Key.keepHistory) { Settings.shared.keepHistory = $0 }

        // 2.5) 收下之后立刻把几条归一规则重新套一遍（4.1.1 / 4.1.4）：
        //   • 文件里可能还带着老的「关于我」——界面上已经没有那个框了，不并进规则就是静默丢失；
        //   • 文件里可能带着分开设的润色/指令型号——界面上也已经没有分开设的入口，
        //     留着就是一条改不动的设置（下拉显示「自定义…」，指令跑的却是另一个型号）；
        //   • 文件里的接入地址可能压根拼不出主机名——界面上同样没有地方能改它，
        //     留着只会让候选表少一台、让错误信息指向一个用户碰不到的东西。
        // 与启动时那几条同一份实现，不各写一遍。
        Settings.shared.normalizePersonalFields()
        Settings.shared.normalizeModelPair()
        Settings.shared.dropJunkPastedHost()

        // 3) 不认识的键：只计数，绝不写进任何地方（API Key 就算被手工塞进来也止步于此）
        for key in settings.keys where !Key.all.contains(key) {
            summary.ignoredKeys.append(key)
        }

        Log.info("Settings imported: +\(summary.vocabularyAdded) vocab, +\(summary.fillerAdded) filler, "
                 + "\(summary.updatedKeys.count) scalars, \(summary.ignoredKeys.count) ignored")
        return summary
    }
}

// MARK: - 设置界面里的按钮动作（面板 + 结果弹窗）

extension SettingsBackup {

    /// 失败原因的显示文字。MTError 的 message 本来就走 tr()；系统错误的 localizedDescription
    /// 跟的是 **macOS 的语言**，和 MicType 的界面语言没关系——中文界面里会突然冒出一句英文
    /// （反过来也一样）。所以先给一句本界面语言的说明，系统原文降级成后面括号里的细节
    /// （细节还是要给：真正的失败原因在里面，"没有写入权限"和"磁盘已满"得能分辨）。
    static func describe(_ error: Error) -> String {
        if let known = error as? MTError { return known.message }
        return failureDetail(systemMessage: error.localizedDescription)
    }

    /// 纯函数，便于单测：拼「本语言的说明（系统原文）」
    static func failureDetail(systemMessage: String) -> String {
        let detail = systemMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return tr("系统报错，但没有给出原因", "The system reported an error without a reason")
        }
        return tr("系统报错", "The system reported an error") + tr("（", " (") + detail + tr("）", ")")
    }

    private static func defaultFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "MicType-Settings-\(f.string(from: Date())).json"
    }

    /// 导出：返回给设置页显示的一行状态（用户取消时返回空串）
    static func runExport() -> String {
        let panel = NSSavePanel()
        panel.title = tr("导出 MicType 设置", "Export MicType Settings")
        panel.nameFieldStringValue = defaultFileName()
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return "" }

        do {
            try exportData().write(to: url, options: .atomic)
            Log.info("Settings exported")
            return tr("已导出到 \(url.lastPathComponent)（不含 API Key）",
                      "Exported to \(url.lastPathComponent) (API keys excluded)")
        } catch {
            Log.warn("Settings export failed: \(describe(error))")
            return tr("导出失败：", "Export failed: ") + describe(error)
        }
    }

    /// 导入：合并后弹一个结果摘要，并返回给设置页显示的一行状态
    static func runImport() -> String {
        let panel = NSOpenPanel()
        panel.title = tr("导入 MicType 设置", "Import MicType Settings")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return "" }

        do {
            let data = try Data(contentsOf: url)
            guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MTError(tr("文件内容不是 JSON 对象", "File is not a JSON object"))
            }
            let summary = try apply(document: document)
            showSummary(summary)
            return tr("已导入：词汇表 +\(summary.vocabularyAdded)，设置 \(summary.updatedKeys.count) 项",
                      "Imported: \(summary.vocabularyAdded) vocabulary entries, \(summary.updatedKeys.count) settings")
        } catch {
            Log.warn("Settings import failed: \(describe(error))")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = tr("导入失败", "Import failed")
            alert.informativeText = describe(error)
                + tr("\n\n当前设置没有任何改动。", "\n\nYour current settings were not changed.")
            alert.addButton(withTitle: tr("好", "OK"))
            alert.runModal()
            return tr("导入失败：", "Import failed: ") + describe(error)
        }
    }

    private static func showSummary(_ summary: ImportSummary) {
        var lines: [String] = []
        lines.append(tr("词汇表：新增 \(summary.vocabularyAdded) 条，已有 \(summary.vocabularySkipped) 条跳过",
                        "Vocabulary: \(summary.vocabularyAdded) added, \(summary.vocabularySkipped) already present"))
        lines.append(tr("口水词：新增 \(summary.fillerAdded) 条，已有 \(summary.fillerSkipped) 条跳过",
                        "Filler words: \(summary.fillerAdded) added, \(summary.fillerSkipped) already present"))
        lines.append(tr("其他设置：覆盖 \(summary.updatedKeys.count) 项",
                        "Other settings: \(summary.updatedKeys.count) overwritten"))
        // 接口地址 / 模型名逐条念出来：这几项决定"文本发给谁、由谁处理"，
        // 只报一句"覆盖 12 项"的话，别人发来的文件把接口换掉了用户也看不出来
        if !summary.notableChanges.isEmpty {
            lines.append(tr("接口与模型（已按文件改动）：", "Endpoints and models (changed by this file):"))
            lines.append(contentsOf: summary.notableChanges.map { "  · " + $0 })
            // 只有地址真的被改了才说这句重话，模型名换一换不至于
            if summary.notableChanges.contains(where: {
                $0.hasPrefix(Key.openaiBaseURL) || $0.hasPrefix(Key.deepseekBaseURL)
                    || $0.hasPrefix(Key.qwenApiHost)
            }) {
                lines.append(tr("接口地址决定你的 API Key 和文本发往哪里——不是自己写的地址请改回去。",
                                "The endpoint decides where your API key and text are sent — change it back if you didn't choose it."))
            }
            // 区域 / 接入地址被改 = 收信主机换了一个司法辖区（润色与云端识别共用这一项）
            if summary.notableChanges.contains(where: {
                $0.hasPrefix(Key.qwenRegion) || $0.hasPrefix(Key.qwenApiHost)
            }) {
                // 4.1.4 起界面上与接入地址有关的控件一个都没有了，所以这句话**不指任何控件**：
                // 只说会发生什么（换一台服务器）、以及它坏了之后会自己回到自动探测
                //（CloudASRSettings.resolveHost 会把连不上的那条丢掉）。
                lines.append(tr("这份文件带来一个百炼接入地址：润色与云端识别会改发到那台服务器（可能是另一个司法辖区）。它一旦连不上，MicType 会丢掉它、自己重新试出一台。",
                                "This file brings its own Model Studio endpoint: polish and cloud recognition will go to that server, possibly in a different jurisdiction. If it stops working, MicType drops it and finds a working one by itself."))
            }
            // 引擎被文件改成云端 = 从此每段录音都会上传。这句重话必须说
            if summary.notableChanges.contains(where: {
                $0.hasPrefix(Key.recognitionEngine) && !$0.hasSuffix(RecognitionEngineChoice.local.rawValue)
            }) {
                lines.append(tr("这份文件把识别引擎改成了云端：以后每段录音都会上传给服务商，并按秒计费。不是自己选的请在「云端 AI」页把「识别也用云端」关掉。",
                                "This file switched recognition to a cloud engine: every recording will be uploaded to that provider and billed by the second. Turn off Also recognize speech in the cloud under Settings → Cloud AI if you did not choose it."))
            }
        }
        if !summary.ignoredKeys.isEmpty {
            lines.append(tr("忽略 \(summary.ignoredKeys.count) 项（不认识或格式不对）",
                            "Ignored \(summary.ignoredKeys.count) entries (unknown or malformed)"))
        }
        if summary.newerSchema {
            lines.append(tr("这份文件来自更新版本的 MicType，只应用了本版认识的设置。",
                            "This file comes from a newer MicType; only settings this version knows were applied."))
        }
        // 4.1 起设置里没有标签页了（概览 + 编辑页），所以英文这边也不能再说 "tab"——
        // 指路一律写成 Settings → Cloud AI，和其它深链那几句同一个说法
        lines.append(tr("API Key 从不导出、也从不导入——请在「云端 AI」页单独填写。",
                        "API keys are never exported or imported — enter them under Settings → Cloud AI."))

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = tr("导入完成", "Import complete")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: tr("好", "OK"))
        alert.runModal()
    }
}
