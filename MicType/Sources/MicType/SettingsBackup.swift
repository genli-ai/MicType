import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - 设置导入导出（路线图 P21）
//
// 为什么做：词汇表、关于我、自定义规则是用户一天天攒出来的，换机 / 重装 / 在 Mac 和 Windows 之间
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
//                             读取端大小写不敏感；认不出的值保持本机当前设置不变（Windows 没有 fn）。
//   polishLevel             ← polishLevel            / PolishLevel          "off" | "smart"
//   vocabulary              ← customVocabulary       / CustomVocabulary     整段原文（逗号/换行分隔）
//   fillerWords             ← fillerWords            / FillerWords          整段原文（逗号/换行分隔）
//   aboutMe                 ← aboutMe                / AboutMe
//   customPolishRules       ← customPolishRules      / CustomPolishRules
//   llmProvider             ← llmProvider            / LlmProvider          "openai" | "deepseek"
//   openaiBaseURL           ← openaiBaseURL          / OpenAiBaseUrl
//                             只接受 https 且带主机名的地址，别的一律忽略（见 isAcceptableBaseURL）
//   deepseekBaseURL         ← deepseekBaseURL        / DeepSeekBaseUrl        同上
//   openaiPolishModel       ← chatModel              / OpenAiPolishModel
//   openaiCommandModel      ← openaiCommandModel     / OpenAiCommandModel
//   deepseekPolishModel     ← deepseekModel          / DeepSeekPolishModel
//   deepseekCommandModel    ← deepseekCommandModel   / DeepSeekCommandModel
//   polishTemperature       ← polishTemperature      / PolishTemperature    数字 0–1.5
//   commandTemperature      ← commandTemperature     / CommandTemperature   数字 0–1.5
//   appLanguage             ← appLanguage            / AppLanguage          "zh" | "en"
//   autoStopSilenceSeconds  ← autoStopSilenceSeconds / （Windows 暂无）      数字，0 = 关，否则 1–5
//   livePreview             ← livePreview            / （Windows 暂无）      布尔
//   playSounds              ← playSounds             / PlaySounds           布尔
//   restoreClipboard        ← restoreClipboard       / RestoreClipboard     布尔
//   keepHistory             ← keepHistory            / （Windows 暂无）      布尔
//
// 不进这个文件：API Key（安全）、模型仓库 / 下载状态（跟本机磁盘绑定）、登录启动（系统级注册）、
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
        static let openaiPolishModel = "openaiPolishModel"
        static let openaiCommandModel = "openaiCommandModel"
        static let deepseekPolishModel = "deepseekPolishModel"
        static let deepseekCommandModel = "deepseekCommandModel"
        static let polishTemperature = "polishTemperature"
        static let commandTemperature = "commandTemperature"
        static let appLanguage = "appLanguage"
        static let autoStopSilenceSeconds = "autoStopSilenceSeconds"
        static let livePreview = "livePreview"
        static let playSounds = "playSounds"
        static let restoreClipboard = "restoreClipboard"
        static let keepHistory = "keepHistory"

        /// 已知键全集——不在这里面的一律忽略并计数（含任何伪装成设置的 Key 字段）
        static let all: Set<String> = [
            hotkey, polishLevel, vocabulary, fillerWords, aboutMe, customPolishRules,
            llmProvider, openaiBaseURL, deepseekBaseURL,
            openaiPolishModel, openaiCommandModel, deepseekPolishModel, deepseekCommandModel,
            polishTemperature, commandTemperature, appLanguage,
            autoStopSilenceSeconds, livePreview, playSounds, restoreClipboard, keepHistory,
        ]
    }

    // MARK: - 导出

    /// 组装导出文档（纯函数，方便单测）
    static func makeDocument(date: Date = Date()) -> [String: Any] {
        let s = Settings.shared
        let settings: [String: Any] = [
            Key.hotkey: s.hotkey.rawValue,
            Key.polishLevel: s.polishLevel.rawValue,
            Key.vocabulary: s.customVocabulary,
            Key.fillerWords: s.customFillerWords,
            Key.aboutMe: s.aboutMe,
            Key.customPolishRules: s.customPolishRules,
            Key.llmProvider: s.llmProvider.rawValue,
            Key.openaiBaseURL: s.openaiBaseURL,
            Key.deepseekBaseURL: s.deepseekBaseURL,
            Key.openaiPolishModel: s.chatModel,
            Key.openaiCommandModel: s.openaiCommandModel,
            Key.deepseekPolishModel: s.deepseekModel,
            Key.deepseekCommandModel: s.deepseekCommandModel,
            Key.polishTemperature: s.polishTemperature,
            Key.commandTemperature: s.commandTemperature,
            Key.appLanguage: L10n.shared.language.rawValue,
            Key.autoStopSilenceSeconds: s.autoStopSilenceSeconds,
            Key.livePreview: s.livePreview,
            Key.playSounds: s.playSounds,
            Key.restoreClipboard: s.restoreClipboard,
            Key.keepHistory: s.keepHistory,
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
        /// 枚举一律大小写不敏感匹配——Windows 端写的是 PascalCase（RightControl / Smart / OpenAi）
        func enumValue<T: CaseIterable & RawRepresentable>(_ key: String, _ assign: (T) -> Void)
            where T.RawValue == String {
            guard let raw = settings[key] else { return }
            guard let text = raw as? String,
                  let match = T.allCases.first(where: { $0.rawValue.compare(text, options: .caseInsensitive) == .orderedSame }) else {
                summary.ignoredKeys.append(key)
                return
            }
            assign(match)
            summary.updatedKeys.append(key)
        }

        enumValue(Key.hotkey) { (v: HotkeyChoice) in Settings.shared.hotkey = v }
        enumValue(Key.polishLevel) { (v: PolishLevel) in Settings.shared.polishLevel = v }
        enumValue(Key.llmProvider) { (v: LLMProvider) in Settings.shared.llmProvider = v }
        // 界面语言走 L10n（@Published，切了要立刻刷新界面；它自己负责落盘）
        enumValue(Key.appLanguage) { (v: AppLanguage) in L10n.shared.language = v }

        string(Key.aboutMe) { Settings.shared.aboutMe = $0 }
        string(Key.customPolishRules) { Settings.shared.customPolishRules = $0 }
        baseURL(Key.openaiBaseURL) { Settings.shared.openaiBaseURL = $0 }
        baseURL(Key.deepseekBaseURL) { Settings.shared.deepseekBaseURL = $0 }
        string(Key.openaiPolishModel, notable: true) { Settings.shared.chatModel = $0 }
        string(Key.openaiCommandModel, notable: true) { Settings.shared.openaiCommandModel = $0 }
        string(Key.deepseekPolishModel, notable: true) { Settings.shared.deepseekModel = $0 }
        string(Key.deepseekCommandModel, notable: true) { Settings.shared.deepseekCommandModel = $0 }

        number(Key.polishTemperature, range: 0...1.5) { Settings.shared.polishTemperature = $0 }
        number(Key.commandTemperature, range: 0...1.5) { Settings.shared.commandTemperature = $0 }
        // 0 = 关；其余落在设置界面允许的 1–5 秒内
        number(Key.autoStopSilenceSeconds, range: 0...5) {
            Settings.shared.autoStopSilenceSeconds = ($0 > 0 && $0 < 1) ? 1 : $0
        }

        bool(Key.livePreview) { Settings.shared.livePreview = $0 }
        bool(Key.playSounds) { Settings.shared.playSounds = $0 }
        bool(Key.restoreClipboard) { Settings.shared.restoreClipboard = $0 }
        // 这条走的是"要不要记录"这个偏好，历史内容本身照旧不进备份文件
        bool(Key.keepHistory) { Settings.shared.keepHistory = $0 }

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
            if summary.notableChanges.contains(where: { $0.hasPrefix(Key.openaiBaseURL) || $0.hasPrefix(Key.deepseekBaseURL) }) {
                lines.append(tr("接口地址决定你的 API Key 和文本发往哪里——不是自己写的地址请改回去。",
                                "The endpoint decides where your API key and text are sent — change it back if you didn't choose it."))
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
        // 标签名 3.3 之后叫「AI」（那一页也管语音指令），这句话得跟着改，别指一个不存在的页
        lines.append(tr("API Key 从不导出、也从不导入——请在「AI」页单独填写。",
                        "API keys are never exported or imported — enter them on the AI tab."))

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = tr("导入完成", "Import complete")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: tr("好", "OK"))
        alert.runModal()
    }
}
