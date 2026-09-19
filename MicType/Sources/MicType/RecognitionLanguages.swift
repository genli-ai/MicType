import Foundation

// MARK: - 识别语言

/// 一条识别语言。
///
/// `modelName` 是**送进模型的英文全名**，不是语言代码：mlx-swift-asr 把 `language` 原样拼进
/// prompt（`language \(language)<asr_text>`，Qwen3ASRTokenizer.buildPrompt），传 "ar" 会让模型
/// 看到字面的「language ar」——等于喂了一句它没见过的指令。名字必须与模型 config.json 的
/// `support_languages` 逐字一致（本表就是从 Qwen3-ASR-0.6B 的 config.json 抄下来的 30 项）。
struct RecognitionLanguage: Identifiable {
    /// 设置里存的值（BCP-47 主代码）。**存代码不存英文名**：模型换代改名时只动本表，用户设置不用迁移。
    let code: String
    /// 送给 MLXASR 的英文全名（逐字对齐 config.json 的 support_languages）
    let modelName: String
    /// 界面上显示的名字（随界面语言切换）
    let displayName: String

    var id: String { code }
}

/// Qwen3-ASR 支持的 30 种语言（另有 22 种**中文**方言，官方没有任何阿语方言清单）。
///
/// 设计上只有「自动 + 显式指定」两种状态，没有任何自动切换：
/// Auto（设置值 ""）= 传 nil 给模型让它自己判；选定某语言 = 传英文全名。
/// 判语言这件事要么交给模型，要么交给用户，MicType 自己永远不猜。
enum RecognitionLanguages {

    /// 「自动」在设置里存空串——空值天生是默认值，老用户升级上来什么都不用改
    static let autoCode = ""

    /// Picker 里排在最前的三种：本产品的两种界面语言 + 阿语（作者在 UAE，v4.0 的重点语言）
    static let priorityCodes = ["zh", "en", "ar"]

    /// 30 种语言。计算属性而不是 static let：displayName 走 tr()，切界面语言要立刻跟上（3.1.1 的坑）
    static var all: [RecognitionLanguage] { [
        RecognitionLanguage(code: "zh", modelName: "Chinese", displayName: tr("中文", "Chinese")),
        RecognitionLanguage(code: "en", modelName: "English", displayName: tr("英语", "English")),
        // 阿语名字在两侧都带上本名：RTL 用户一眼认出自己的语言
        RecognitionLanguage(code: "ar", modelName: "Arabic", displayName: tr("阿拉伯语（العربية）", "Arabic (العربية)")),
        RecognitionLanguage(code: "yue", modelName: "Cantonese", displayName: tr("粤语", "Cantonese")),
        RecognitionLanguage(code: "de", modelName: "German", displayName: tr("德语", "German")),
        RecognitionLanguage(code: "fr", modelName: "French", displayName: tr("法语", "French")),
        RecognitionLanguage(code: "es", modelName: "Spanish", displayName: tr("西班牙语", "Spanish")),
        RecognitionLanguage(code: "pt", modelName: "Portuguese", displayName: tr("葡萄牙语", "Portuguese")),
        RecognitionLanguage(code: "id", modelName: "Indonesian", displayName: tr("印尼语", "Indonesian")),
        RecognitionLanguage(code: "it", modelName: "Italian", displayName: tr("意大利语", "Italian")),
        RecognitionLanguage(code: "ko", modelName: "Korean", displayName: tr("韩语", "Korean")),
        RecognitionLanguage(code: "ru", modelName: "Russian", displayName: tr("俄语", "Russian")),
        RecognitionLanguage(code: "th", modelName: "Thai", displayName: tr("泰语", "Thai")),
        RecognitionLanguage(code: "vi", modelName: "Vietnamese", displayName: tr("越南语", "Vietnamese")),
        RecognitionLanguage(code: "ja", modelName: "Japanese", displayName: tr("日语", "Japanese")),
        RecognitionLanguage(code: "tr", modelName: "Turkish", displayName: tr("土耳其语", "Turkish")),
        RecognitionLanguage(code: "hi", modelName: "Hindi", displayName: tr("印地语", "Hindi")),
        RecognitionLanguage(code: "ms", modelName: "Malay", displayName: tr("马来语", "Malay")),
        RecognitionLanguage(code: "nl", modelName: "Dutch", displayName: tr("荷兰语", "Dutch")),
        RecognitionLanguage(code: "sv", modelName: "Swedish", displayName: tr("瑞典语", "Swedish")),
        RecognitionLanguage(code: "da", modelName: "Danish", displayName: tr("丹麦语", "Danish")),
        RecognitionLanguage(code: "fi", modelName: "Finnish", displayName: tr("芬兰语", "Finnish")),
        RecognitionLanguage(code: "pl", modelName: "Polish", displayName: tr("波兰语", "Polish")),
        RecognitionLanguage(code: "cs", modelName: "Czech", displayName: tr("捷克语", "Czech")),
        RecognitionLanguage(code: "fil", modelName: "Filipino", displayName: tr("菲律宾语", "Filipino")),
        RecognitionLanguage(code: "fa", modelName: "Persian", displayName: tr("波斯语", "Persian")),
        RecognitionLanguage(code: "el", modelName: "Greek", displayName: tr("希腊语", "Greek")),
        RecognitionLanguage(code: "ro", modelName: "Romanian", displayName: tr("罗马尼亚语", "Romanian")),
        RecognitionLanguage(code: "hu", modelName: "Hungarian", displayName: tr("匈牙利语", "Hungarian")),
        RecognitionLanguage(code: "mk", modelName: "Macedonian", displayName: tr("马其顿语", "Macedonian")),
    ] }

    /// Picker 顺序：中文 / 英语 / 阿语在前（「Auto」由界面自己放在最上面），其余按当前界面语言的
    /// 显示名排序——中文界面按拼音、英文界面按字母，都是用户能扫的顺序。
    static var pickerOrdered: [RecognitionLanguage] {
        let table = all
        let head = priorityCodes.compactMap { code in table.first { $0.code == code } }
        let rest = table.filter { !priorityCodes.contains($0.code) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return head + rest
    }

    /// 设置值 → 送给模型的英文全名。**Auto / 认不出来的脏值一律 nil**（= 让模型自动检测）：
    /// 一条坏设置绝不能让识别退化成「language 某个乱码」。纯函数，可单测。
    static func modelLanguage(for code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "auto" else { return nil }
        return all.first { $0.code == trimmed }?.modelName
    }

    // MARK: 热词上下文

    /// 热词上下文的前缀跟着**会话语言**走，而不是永远中文。
    ///
    /// 老实现无论说什么语言都硬写「常用词汇：」，等于用一句中文系统提示去偏置一个已知会复读
    /// 词表的模型（brief §3.4）——英语/阿语会话里既影响输出风格，又白占 800 字预算里的中文。
    ///
    /// 判定只有两档，且不猜：
    ///   • 明确选了中文 / 粤语 → 中文前缀；
    ///   • Auto → 看词表本身有没有 CJK（用户的词表是中文的，会话大概率也是中文）；
    ///   • 其余语言（英语、阿语……）→ 英文前缀。
    static func hotwordPrefix(languageCode: String, terms: [String]) -> String {
        if usesChinesePrefix(languageCode: languageCode, terms: terms) { return "常用词汇：" }
        return "Common terms: "
    }

    /// 词条之间的分隔符也跟着前缀走：中文用「、」，其他语言用逗号加空格
    static func hotwordSeparator(languageCode: String, terms: [String]) -> String {
        usesChinesePrefix(languageCode: languageCode, terms: terms) ? "、" : ", "
    }

    private static func usesChinesePrefix(languageCode: String, terms: [String]) -> Bool {
        let code = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if code == "zh" || code == "yue" { return true }
        if code.isEmpty || code == "auto" {
            return terms.contains { containsCJK($0) }
        }
        return false
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value)      // CJK 统一汉字（含扩展 A）
                || (0xF900...0xFAFF).contains(scalar.value)  // 兼容汉字
                || (0x3040...0x30FF).contains(scalar.value)  // 平假名 / 片假名
        }
    }

    /// 词汇表作为热词上下文喂给模型（decoder 层的第一道纠正）。
    /// 词表为空返回 nil（绝不送一个只有前缀的上下文——那正是空音频复读的燃料）。
    /// 800 字上限是模型侧的口径，截断只发生在词条串上，前缀永远完整。
    static func hotwordContext(terms: [String], languageCode: String, limit: Int = 800) -> String? {
        guard !terms.isEmpty else { return nil }
        var joined = terms.joined(separator: hotwordSeparator(languageCode: languageCode, terms: terms))
        if joined.count > limit { joined = String(joined.prefix(limit)) }
        return hotwordPrefix(languageCode: languageCode, terms: terms) + joined
    }
}
