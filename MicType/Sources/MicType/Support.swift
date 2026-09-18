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

    /// 清理识别引擎的原始输出：去掉标记、折叠复读幻觉
    static func cleanTranscript(_ text: String) -> String {
        var t = text
        // 去掉 [BLANK_AUDIO]、(字幕) 之类的标记
        for pattern in ["\\[[^\\]]*\\]", "\\([^)]*\\)"] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                t = regex.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
            }
        }
        // 折叠"复读机"式重复：同一短语连续出现 3 次以上时只保留一次
        if let regex = try? NSRegularExpression(pattern: "(.{2,24}?)\\1{2,}", options: [.dotMatchesLineSeparators]) {
            t = regex.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1")
        }
        // 整大段内容被原样复述一遍也只保留一次
        if let regex = try? NSRegularExpression(pattern: "(.{12,400}?)\\1+", options: [.dotMatchesLineSeparators]) {
            t = regex.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 词汇表硬替换（"错写=正写"词条）：确定性字符串替换，零耗时、不依赖模型。
    /// 完全同音的专有名词（如 杰文→捷文）概率方法救不了，这是最后一道硬保证。
    static func applyVocabReplacements(_ text: String) -> String {
        var t = text
        for (wrong, right) in Settings.shared.vocabularyReplacements {
            t = t.replacingOccurrences(of: wrong, with: right)
        }
        return t
    }

    /// 中英混合标点修正：英文内容后面的全角标点改为半角（像豆包那样）
    /// 例：「to test。」→「to test.」  「iPhone，然后」→「iPhone, 然后」
    static func fixMixedPunctuation(_ text: String) -> String {
        var t = text
        let pairs: [(String, String)] = [
            ("。", "."), ("，", ","), ("？", "?"), ("！", "!"), ("：", ":"), ("；", ";"),
        ]
        for (full, half) in pairs {
            // \p{Latin} 覆盖带变音符的西文字母（café、über 等）
            if let re = try? NSRegularExpression(pattern: "([\\p{Latin}0-9])" + full) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t),
                                                withTemplate: "$1" + half)
            }
        }
        // 半角句读后若紧跟文字（字母或汉字），补一个空格
        if let re = try? NSRegularExpression(pattern: "([.,!?;:])([\\p{Latin}\\u4e00-\\u9fff])") {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t),
                                            withTemplate: "$1 $2")
        }
        return t
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
}
