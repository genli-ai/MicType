import AppKit
import AVFoundation
import ApplicationServices

// MARK: - 错误类型

struct MTError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - 路径

enum Paths {
    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MicType", isDirectory: true)
        // 改名迁移：把旧的 VoiceFlow 数据目录（含约 860MB 识别模型）原地改名，免重新下载
        let legacy = base.appendingPathComponent("VoiceFlow", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var modelsDir: URL {
        let dir = appSupportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - 文本后处理

enum TextPostProcessor {

    /// 西文"词内字符"类（含带变音符的西文字母）：只有西文词条才需要词边界，CJK 不需要
    private static let latinClass = "[A-Za-z0-9\u{00C0}-\u{024F}]"
    /// 句读 / 空白：判断一个中文口水词是否"独立成分"的边界字符集
    private static let boundaryClass = "\\s，。！？、；：…—,.!?;:"
    /// 收尾清理会碰的句读（删词后留下的重复标点、句首孤儿标点）
    private static let punctClass = "，。！？、；：,.!?;:"

    // MARK: 清理识别原文

    /// 清理识别引擎的原始输出：去标记、折叠复读幻觉、删用户自定义口水词
    static func cleanTranscript(_ text: String) -> String {
        cleanTranscript(text, fillerWords: Settings.shared.fillerWords)
    }

    /// 纯函数版（可单测）。fillerWords 为空时行为与历史版本完全一致——口水词过滤是纯粹的用户选项。
    static func cleanTranscript(_ text: String, fillerWords: [String]) -> String {
        var t = text
        // 引擎控制 token 与非语音伪影。顺序有讲究：先删 <|zh|>/<|endoftext|> 这类成对标记，
        // 再删 <TAG>/<br>，否则后者会把前者切碎、留下 "zh|" 这种残渣。
        // <TAG> 只认"紧跟字母、内部无空格"的形式，避免误伤用户真说出口的「a < b > c」。
        for pattern in ["<\\|[^>]*\\|>",
                        "<[A-Za-z][A-Za-z0-9_/\\-]{0,30}>",
                        "\\[[^\\]]*\\]",            // [BLANK_AUDIO]
                        "\\([^)]*\\)",              // (字幕)
                        "[♪♫♬]+"] {                 // 音乐符号：非语音段的常见幻觉
            t = replaceAll(t, pattern, "")
        }
        // 折叠"复读机"式重复：同一短语连续出现 3 次以上时只保留一次
        t = replaceAll(t, "(.{2,24}?)\\1{2,}", "$1", options: [.dotMatchesLineSeparators])
        // 整大段内容被原样复述一遍也只保留一次
        t = replaceAll(t, "(.{12,400}?)\\1+", "$1", options: [.dotMatchesLineSeparators])
        t = removeFillerWords(t, fillerWords: fillerWords)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 本地口水词过滤：用户列出的词在本机就地删掉，不依赖云端润色（无 Key 的纯听写路径也能用）。
    /// 分寸是刻意保守的（宁可少删，绝不改变原意）：
    ///   • 纯西文词条（um / uh / you know）按整词删、大小写不敏感；词内出现不动（"like" 不动 "likely"）。
    ///   • 其他（中文 嗯 / 那个 / 就是说）只在"两侧都是句读、空白或文本边界"时删——
    ///     所以「那个人」「不嗯」里的词永远不动，只有独立成分的口水词会被删。
    ///   • 删完做收尾：合并因此出现的重复标点、去掉标点前的空格与句首孤儿标点。
    static func removeFillerWords(_ text: String, fillerWords: [String]) -> String {
        // 去空白用 whitespacesAndNewlines：.whitespaces 不含 \r，带尾随 CR 的口水词
        // 经 escapedPattern 转义后永远匹配不到——用户以为开了过滤，其实一个词都没删
        let fillers = fillerWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !fillers.isEmpty, !text.isEmpty else { return text }

        var t = text
        for filler in fillers {
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            if isLatinToken(filler) {
                // (?<!类) / (?!类) 在文本首尾也成立，等价于西文词边界
                t = replaceAll(t, "(?<!\(latinClass))" + escaped + "(?!\(latinClass))", "",
                               options: [.caseInsensitive])
            } else {
                // (?<![^边界]) = "前面没有字符，或前面那个字符是边界"，定长、比变长 lookbehind 稳
                t = replaceAll(t, "(?<![^\(boundaryClass)])" + escaped + "(?![^\(boundaryClass)])", "")
            }
        }
        // 收尾：删词留下的空洞
        t = replaceAll(t, "([\(punctClass)])[ \\t]*\\1+", "$1")            // 、、 → 、
        t = replaceAll(t, "[，、,][ \\t]*(?=[\(punctClass)])", "")           // ，。 → 。（逗号紧跟其他句读必是残留）
        t = replaceAll(t, "[ \\t]{2,}", " ")
        t = replaceAll(t, "[ \\t]+([\(punctClass)])", "$1")
        t = replaceAll(t, "^[ \\t]*[\(punctClass)]+[ \\t]*", "")           // 句首孤儿标点
        return t
    }

    // MARK: 词汇表硬替换

    /// 词汇表硬替换（"错写=正写"词条）：确定性字符串替换，零耗时、不依赖模型。
    /// 完全同音的专有名词（如 杰文→捷文）概率方法救不了，这是最后一道硬保证。
    static func applyVocabReplacements(_ text: String) -> String {
        applyVocabReplacements(text, replacements: Settings.shared.vocabularyReplacements)
    }

    /// 纯函数版（可单测）。三条规则都是为了不"腐蚀"文本：
    ///   1. 最长错写优先——短词条不能先把包含它的长词条吃掉（「文档」不许污染「文档助手」）。
    ///   2. 西文词条大小写不敏感、且要求词边界；正写一侧原样写出（用户填的大小写就是他要的）。
    ///   3. 单趟扫描：替换结果不再参与匹配，避免 A→B、B→C 串成链。
    static func applyVocabReplacements(_ text: String,
                                       replacements: [(wrong: String, right: String)]) -> String {
        guard !text.isEmpty else { return text }
        let entries = replacements
            .filter { !$0.wrong.isEmpty }
            .enumerated()
            .sorted { a, b in
                // 长的在前；等长时保持用户填写顺序，结果才是确定的（字典序不定曾是老实现的隐患）
                if a.element.wrong.count != b.element.wrong.count {
                    return a.element.wrong.count > b.element.wrong.count
                }
                return a.offset < b.offset
            }
            .map { $0.element }
        guard !entries.isEmpty else { return text }

        // 一条大正则：分支顺序 = 最长优先顺序，命中哪个捕获组就用哪条词条的正写
        let pattern = entries.map { "(" + vocabPattern(for: $0.wrong) + ")" }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            Log.warn("Vocab replacement regex build failed, falling back to plain replace")
            var fallback = text
            for (wrong, right) in entries {
                fallback = fallback.replacingOccurrences(of: wrong, with: right)
            }
            return fallback
        }

        let ns = text as NSString
        var out = ""
        var cursor = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match = match else { return }
            var hit = -1
            for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                hit = group - 1
                break
            }
            guard hit >= 0, hit < entries.count else { return }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += entries[hit].right
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// 西文词条两侧补词边界；中日韩词条不补（中文没有空格，补了就永远匹配不上）
    private static func vocabPattern(for wrong: String) -> String {
        var pattern = NSRegularExpression.escapedPattern(for: wrong)
        if let first = wrong.unicodeScalars.first, isLatinWordScalar(first) {
            pattern = "(?<!\(latinClass))" + pattern
        }
        if let last = wrong.unicodeScalars.last, isLatinWordScalar(last) {
            pattern += "(?!\(latinClass))"
        }
        return pattern
    }

    // MARK: 润色保真校验（drift guard）

    /// 润色保真校验：纯机械比对，零 LLM 成本、零网络往返。
    /// 返回 nil = 通过；否则返回失败原因（写日志用，不直接给用户看）。
    /// 三条判据都是"模型跑飞"的强信号——数字被改、否定被吞、内容被大段砍掉，
    /// 正是语音输入里代价最高的三种错。宁可多回退一次原文，也不让改错的稿子进用户的输入框。
    static func polishDriftCheck(raw: String, polished: String) -> String? {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return nil }
        if p.isEmpty { return "polished text is empty" }

        // 1) 数字多重集：只看数字字符本身，所以 1,000 / 1000 / 1 000 视为一致；全角数字先折半角。
        //    金额、日期、房号改错一位就是事故，这里不留容差。
        let rawDigits = digitMultiset(r)
        let polDigits = digitMultiset(p)
        if rawDigits != polDigits {
            return "digits changed raw=\(digitSummary(rawDigits)) polished=\(digitSummary(polDigits))"
        }
        // 2) 否定词计数：允许少量增减（删口头重复、句式改写会动一两个），差太多说明语义被翻转
        let rawNeg = negationCount(r)
        let polNeg = negationCount(p)
        if abs(rawNeg - polNeg) > max(1, rawNeg / 3) {
            return "negation drift raw=\(rawNeg) polished=\(polNeg)"
        }
        // 3) 长度比：长输入被砍到三分之一以下 = 模型在"总结"而不是"润色"。
        //    短输入不查——一两句话的轻清理本来就可能砍掉一半（全是语气词）。
        if r.count > 40, Double(p.count) < Double(r.count) * 0.35 {
            return "too short raw=\(r.count) polished=\(p.count)"
        }
        return nil
    }

    private static func digitMultiset(_ text: String) -> [Character: Int] {
        var counts: [Character: Int] = [:]
        for scalar in text.unicodeScalars {
            var value = scalar.value
            if (0xFF10...0xFF19).contains(value) { value -= 0xFF10 - 0x30 }  // 全角数字折半角
            guard (0x30...0x39).contains(value), let half = Unicode.Scalar(value) else { continue }
            counts[Character(half), default: 0] += 1
        }
        return counts
    }

    private static func digitSummary(_ counts: [Character: Int]) -> String {
        counts.keys.sorted()
            .map { String(repeating: String($0), count: counts[$0] ?? 0) }
            .joined()
    }

    private static func negationCount(_ text: String) -> Int {
        var count = text.reduce(0) { $0 + ("不没无别未".contains($1) ? 1 : 0) }
        if let regex = try? NSRegularExpression(pattern: "\\b(not|no|never)\\b|n['’]t",
                                                options: [.caseInsensitive]) {
            count += regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        return count
    }

    // MARK: 标点

    /// 中英混合标点修正：英文内容后面的全角标点改为半角（像豆包那样）
    /// 例：「to test。」→「to test.」  「iPhone，然后」→「iPhone, 然后」
    static func fixMixedPunctuation(_ text: String) -> String {
        var t = text
        let pairs: [(String, String)] = [
            ("。", "."), ("，", ","), ("？", "?"), ("！", "!"), ("：", ":"), ("；", ";"),
        ]
        for (full, half) in pairs {
            // \p{Latin} 覆盖带变音符的西文字母（café、über 等）
            t = replaceAll(t, "([\\p{Latin}0-9])" + full, "$1" + half)
        }
        // 半角句读后若紧跟文字（字母或汉字），补一个空格
        t = replaceAll(t, "([.,!?;:])([\\p{Latin}\\u4e00-\\u9fff])", "$1 $2")
        return t
    }

    // MARK: 小工具

    private static func replaceAll(_ text: String, _ pattern: String, _ template: String,
                                   options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text,
                                              range: NSRange(text.startIndex..., in: text),
                                              withTemplate: template)
    }

    private static func isLatinWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: return true
        default: return false
        }
    }

    /// 纯西文词条（允许词内的空格、连字符、撇号，如 "you know" / "kind-of" / "don't"）
    private static func isLatinToken(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy {
            isLatinWordScalar($0) || $0 == " " || $0 == "-" || $0 == "'" || $0 == "’"
        }
    }
}

// MARK: - 静音闸门

/// 松手之后「这段音频要不要送去识别」的判据（路线图 bug 9）。
///
/// 老实现是一条线：峰值 < 0.012 就整段丢掉，报「没有听到内容」。问题在于它同时承担了两件事——
/// 「真的没开口」和「声音太小」——而后者是**用户完全可以救回来的情况**（挪近一点、换只麦克风），
/// 却被当成误触悄悄丢了，用户只知道"又没识别到"，不知道该做什么。
///
/// 所以拆成三档：
///   • .silent（峰值 < 0.006）＝ 基本等于数字静音，误触或压根没开口 → 不送识别。
///     这道闸门还有第二个作用：空音频最容易诱发模型把热词上下文"复读"成识别结果（3.2.2），
///     所以它必须留着，只是线压低到"真静音"那一档。
///   • .faint（0.006 ≤ 峰值 < 0.02 且 RMS 极小）＝ 远处说话 / 麦克风没选对 → **照样送识别**
///     （这一档常常是能识别出来的，凭什么不给用户试），只有识别真的出来空的时候才提示"声音太小"。
///   • .normal ＝ 正常走。
/// 光看峰值不够：一声咳嗽也能顶出 0.05 的峰值而整段没人声，RMS 才反映"整段有多少能量"，
/// 两个一起看才分得清"小声说了一整段"和"安静里蹦了一下"。
///
/// 纯函数、可单测，不碰任何设置与 UI。阈值是常量而不是设置项：这是识别链路的内部判据，
/// 不是用户该调的旋钮（要调的是"麦克风选哪只"）。
enum SilenceGate {

    enum Decision: String, Equatable {
        /// 太短，当误触丢弃（静默）
        case tooShort
        /// 几乎数字静音，不送识别
        case silent
        /// 声音很小但不是静音：照样送识别，识别为空时给"声音太小"的针对性提示
        case faint
        case normal
    }

    /// 低于这个时长一律当误触（手滑碰到热键），静默丢弃
    static let minDurationSeconds: Double = 0.4
    /// "真静音"线：低于它就不送识别
    static let silentPeak: Float = 0.006
    /// "声音太小"线：峰值在 [silentPeak, faintPeak) 且 RMS 也极小 → .faint
    static let faintPeak: Float = 0.02
    static let faintRMS: Float = 0.004

    static func decide(peak: Float, rms: Float, duration: Double) -> Decision {
        if duration < minDurationSeconds { return .tooShort }
        // 写成 !(peak >= x) 而不是 peak < x：NaN（转换器出岔子时可能出现）两种比较都为假，
        // 前者会把它判成 .silent（安全侧），后者会把一段坏数据送进识别
        if !(peak >= silentPeak) { return .silent }
        if peak < faintPeak, rms < faintRMS { return .faint }
        return .normal
    }

    /// 峰值 + RMS 一趟算完（5 分钟录音 ≈ 480 万个采样，扫两遍没必要）。
    /// 空数组返回 (0, 0) → decide 判 .silent，和"什么都没录到"一致。
    static func stats(_ samples: [Float]) -> (peak: Float, rms: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        var peak: Float = 0
        var sum: Double = 0     // 用 Double 累加：几百万个平方项用 Float 累加会把小值吃掉
        for v in samples {
            let a = abs(v)
            if a > peak { peak = a }
            sum += Double(v) * Double(v)
        }
        return (peak, Float((sum / Double(samples.count)).squareRoot()))
    }
}

// MARK: - 提示音

/// 四个提示音。自带短音（Resources/Sounds/*.wav，由 scripts/generate_sounds.py 生成），
/// 而不是系统的 Pop/Glass/Basso/Bottle：系统警告音是"出事了"的语义，语音输入一天要响几十次，
/// 而且用户可以在系统设置里把它们换掉，我们就彻底失去了对提示音的控制。
/// 资源缺失（比如直接跑 .build 里的裸可执行文件，没打成 .app）时退回老的系统音，不至于静音。
enum Sounds {

    private enum Cue: String {
        case start, success, error, cancel

        /// 资源缺失时的兜底：3.2.19 之前一直用的那四个系统音
        var systemFallback: String {
            switch self {
            case .start:   return "Pop"
            case .success: return "Glass"
            case .error:   return "Basso"
            case .cancel:  return "Bottle"
            }
        }
    }

    /// NSSound 每次构造都要读文件解码，而提示音是高频路径 → 首次用到时加载一次并留着。
    /// 只在主线程访问（所有 play* 调用点都在主线程）。
    private static var cache: [Cue: NSSound] = [:]

    private static func sound(_ cue: Cue) -> NSSound? {
        if let cached = cache[cue] { return cached }
        var loaded: NSSound? = nil
        if let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav",
                                     subdirectory: "Sounds") {
            loaded = NSSound(contentsOf: url, byReference: false)
            if loaded == nil { Log.warn("Sound decode failed: \(cue.rawValue).wav") }
        }
        if loaded == nil {
            Log.warn("Bundled sound missing: \(cue.rawValue).wav — falling back to system sound")
            loaded = NSSound(named: cue.systemFallback)
        }
        if let loaded = loaded { cache[cue] = loaded }
        return loaded
    }

    private static func play(_ cue: Cue) {
        guard Settings.shared.playSounds else { return }
        guard let s = sound(cue) else { return }
        // 复用同一个 NSSound：上一声还没放完就再触发时必须先 stop，否则 play() 被忽略
        if s.isPlaying { s.stop() }
        s.play()
    }

    static func playStart()   { play(.start) }
    static func playSuccess() { play(.success) }
    static func playError()   { play(.error) }
    static func playCancel()  { play(.cancel) }
}

// MARK: - 权限

enum Permissions {

    static var isAccessibilityTrusted: Bool {
        return AXIsProcessTrusted()
    }

    /// 弹出系统的辅助功能授权提示
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var microphoneStatus: AVAuthorizationStatus {
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var microphoneGranted: Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// 确保麦克风权限，completion 在主线程回调
    static func ensureMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    /// 键盘设置页：用 Fn / 🌐 当热键的人要去这里把「按下🌐键」改成「不执行任何操作」，
    /// 否则每次触发都会被系统抢去弹输入法切换或表情面板。
    static func openKeyboardSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
