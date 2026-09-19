import Foundation

// MARK: - 概览页三张卡上的那一句话

/// 设置窗口 4.0.2 起开在**概览**上（用户 2026-09-20 拍板的 Plan C）：三张卡——
/// 「输入」「本地识别」「云端 AI」，每张只有标题 + 一句话 + 一颗「更改」。
/// 那一句话就是这一层拼的。
///
/// 为什么非得是纯函数：这一句是用户判断"要不要点进去"的**唯一**依据，说错一个词
/// 就会让他去改一个本来没毛病的设置；而视图里现拼的字符串是单测钉不住的
/// （4.0.1 四个标签页各自的介绍语就是这么一页一个说法漂起来的）。
///
/// 两条纪律：
///   • **句子只陈述现状，徽章只说要动手的那件事**——徽章不复述句子里已经说过的话；
///   • 没有需要处理的事就**没有徽章**：常驻的橙色标记两天之内就会被眼睛滤掉。
enum SettingsSummary {

    /// 徽章的分量。颜色由它决定，而不是由调用方顺手挑一个——
    /// 「正在下载 42%」是一件自己会好的事，和「还没填 Key」长成同一个橙色，
    /// 用户学会的是"橙色＝不用管"，那两枚徽章就都白挂了。
    enum BadgeLevel: Equatable {
        /// 要你动手（没下模型、没填 Key、配置没填完）
        case attention
        /// 正在进行，不需要你动手（下载中）
        case progress
    }

    /// 一张卡的文字。badge == nil = 这张卡现在不需要你管。
    struct Card: Equatable {
        let sentence: String
        let badge: String?
        var level: BadgeLevel = .attention
    }

    /// 三段事实并排，不连成句子：卡片只有一行，一行装得下才有意义
    private static let dot = " · "

    // MARK: - 输入

    /// 「右 Option (⌥) · 悬浮窗在屏幕底部 · 提示音开」
    ///
    /// 没有徽章：这张卡里的每一项都是用户自己选的，没有"坏掉"的状态。
    /// 权限缺失不在这里说——那是整页顶上那条横幅的事（缺了就没法用，不只是输入不对劲）。
    static func inputSummary(hotkey: HotkeyChoice,
                             overlayPosition: OverlayPosition,
                             sounds: Bool,
                             launchAtLogin: Bool) -> String {
        var parts = [hotkey.displayName,
                     overlayPhrase(overlayPosition),
                     sounds ? tr("提示音开", "Sounds on") : tr("提示音关", "Sounds off")]
        // 开机自启只在开着时占位置：关着是出厂默认，说出来等于用一格讲一件没发生的事
        if launchAtLogin { parts.append(tr("开机自启", "Starts at login")) }
        return parts.joined(separator: dot)
    }

    private static func overlayPhrase(_ position: OverlayPosition) -> String {
        switch position {
        case .bottomCenter: return tr("悬浮窗在屏幕底部", "Overlay at the bottom")
        case .topCenter: return tr("悬浮窗在屏幕顶部", "Overlay at the top")
        case .nearCursor: return tr("悬浮窗跟随鼠标", "Overlay follows the pointer")
        }
    }

    // MARK: - 本地识别

    /// 本机模型这一刻的状态。下载中带百分比：那是卡片上唯一会自己变的数字，
    /// 用户盯着它判断"还要不要等"。
    enum ModelState: Equatable {
        case ready(name: String)
        case missing(name: String)
        case downloading(percent: Int)
        /// 目录里有更合适的一档（或当前这份有新修订）。**不是坏状态**：现在这份照常能用，
        /// 所以句子照说"已就绪"，只多一枚徽章告诉他有得换。
        case upgradeAvailable(name: String)
    }

    /// 「自动检测语言 · 词汇表 12 条 · 模型 0.6B 已就绪」
    /// - micName: 用户指定的麦克风名；空串 = 跟随系统默认，那就不占一格
    static func recognitionSummary(language: String,
                                   vocabCount: Int,
                                   modelState: ModelState,
                                   micName: String) -> Card {
        var parts = [languagePhrase(language)]
        if vocabCount > 0 {
            parts.append(tr("词汇表 \(vocabCount) 条", "\(vocabCount) vocabulary terms"))
        }
        parts.append(modelPhrase(modelState))
        let mic = micName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mic.isEmpty { parts.append(tr("麦克风 \(mic)", "Microphone \(mic)")) }
        return Card(sentence: parts.joined(separator: dot),
                    badge: modelBadge(modelState),
                    level: modelBadgeLevel(modelState))
    }

    /// 识别语言那一格。**认不出来的脏值一律当「自动」**——和 RecognitionLanguages.modelLanguage
    /// 同一条纪律：一条坏设置不能让这句话报出一个用户根本没选过的语言。
    private static func languagePhrase(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let language = RecognitionLanguages.all.first(where: { $0.code == trimmed }) else {
            return tr("自动检测语言", "Detects the language")
        }
        return tr("识别 \(language.displayName)", "Recognizes \(language.displayName)")
    }

    private static func modelPhrase(_ state: ModelState) -> String {
        switch state {
        case .ready(let name), .upgradeAvailable(let name):
            return tr("模型 \(name) 已就绪", "Model \(name) ready")
        case .missing(let name):
            return tr("模型 \(name) 未下载", "Model \(name) not downloaded")
        case .downloading(let percent):
            return tr("模型下载中 \(percent)%", "Model downloading \(percent)%")
        }
    }

    /// 下载中是唯一一件"自己会好"的事：它不该和"你得去下一个模型"同色
    private static func modelBadgeLevel(_ state: ModelState) -> BadgeLevel {
        if case .downloading = state { return .progress }
        return .attention
    }

    private static func modelBadge(_ state: ModelState) -> String? {
        switch state {
        case .ready: return nil
        case .missing: return tr("模型未下载", "Model missing")
        case .downloading(let percent): return tr("正在下载 \(percent)%", "Downloading \(percent)%")
        case .upgradeAvailable: return tr("有更合适的模型", "Better model available")
        }
    }

    // MARK: - 云端 AI

    /// 这一档的凭据够不够用。三态，全部有对应的真实判据（见 LLMCatalog.aiReady）：
    /// 只有"有没有 Key"两态的话，填了 Key 却没填型号名的人会读到一句「已连通 ✓」，
    /// 而他按住说指令什么都不会发生。
    enum KeyState: Equatable {
        /// 钥匙串里没有这一档的 Key（本机模型那一档不需要 Key，也算 ready）
        case missing
        /// 有凭据，但地址或型号拼不出来——按住说指令这会儿跑不起来
        case incomplete
        /// 凭据、地址、型号齐了。Key 是验证通过才写进钥匙串的（见 KeyVerifier），
        /// 所以"存着"就等于"验过"
        case ready
    }

    /// 「未启用 · 只用本地」/「OpenAI · gpt-5.6-sol · 已连通 ✓」/「阿里云 · qwen3.8-max · 云端识别开」
    ///
    /// 云端识别开着时占掉第三格：那是这一刻最贵、最该看见的一条事实（每段录音都在上传）。
    static func cloudSummary(mode: AIUsageMode,
                             provider: LLMProvider,
                             model: String,
                             keyState: KeyState,
                             cloudRecognition: Bool) -> Card {
        guard mode == .withAI else {
            return Card(sentence: tr("未启用 · 只用本地", "Off · local only"), badge: nil)
        }
        var parts = [provider.segmentName]
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { parts.append(name) }
        parts.append(cloudRecognition ? tr("云端识别开", "Cloud recognition on")
                                      : keyPhrase(keyState))
        return Card(sentence: parts.joined(separator: dot), badge: keyBadge(keyState))
    }

    private static func keyPhrase(_ state: KeyState) -> String {
        switch state {
        case .missing: return tr("还没填 Key", "No key yet")
        case .incomplete: return tr("配置没填完", "Setup incomplete")
        case .ready: return tr("已连通 ✓", "Connected ✓")
        }
    }

    private static func keyBadge(_ state: KeyState) -> String? {
        switch state {
        case .ready: return nil
        case .missing: return tr("还没填 Key", "No key yet")
        case .incomplete: return tr("配置没填完", "Setup incomplete")
        }
    }
}
