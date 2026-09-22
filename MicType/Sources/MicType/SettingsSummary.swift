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

    /// 「右 Option (⌥) · 词汇表 11 条 · 有自定义规则 · 开机自启」
    ///
    /// 键名仍然排在最前面，哪怕它只有一个值（见 Settings.hotkey）：这张卡回答的第一个问题
    /// 就是"按哪个键"，把它省掉，用户要按的那颗键在设置窗口首页上就一个字都没有了。
    ///
    /// 4.1.6 起「写作偏好」（词汇表 + 自定义规则）也归这张卡（控件搬到了「输入」页）。
    /// 紧跟在键名后面、排在悬浮窗与提示音之前，和页内的段序一致——**两处顺序对不上时，
    /// 点进去的人会先在屏幕上找一遍自己刚读到的那一格**。
    /// 两项都遵守同一条纪律：**空着就不占格子**（和开机自启一样，出厂默认不值一格）。
    ///
    /// 没有徽章：这张卡里的每一项都是用户自己选的，没有"坏掉"的状态。
    /// 权限缺失不在这里说——那是整页顶上那条横幅的事（缺了就没法用，不只是输入不对劲）。
    ///
    /// 4.3.3 去掉了悬浮窗位置与提示音两格：那两个开关已经从「输入」页上撤了
    /// （用户 2026-09-22 嫌那一页杂），卡片上再念一遍就成了"点进去找不到的东西"。
    /// 现在这张卡剩下的每一格都在页内改得到。
    static func inputSummary(launchAtLogin: Bool,
                             vocabCount: Int,
                             hasCustomRules: Bool) -> String {
        var parts = [HotkeyChoice.rightOption.displayName]
        if vocabCount > 0 { parts.append(vocabularyPhrase(vocabCount)) }
        // 规则的**内容**永远不上卡片（那是他写给 AI 的私人偏好，概览只说"有没有"）
        if hasCustomRules { parts.append(tr("有自定义规则", "Custom rules set")) }
        // 开机自启只在开着时占位置：关着是出厂默认，说出来等于用一格讲一件没发生的事
        if launchAtLogin { parts.append(tr("开机自启", "Starts at login")) }
        return parts.joined(separator: dot)
    }

    /// 词汇表那一格。**只有一个出处**：4.1.6 之前它长在「本地识别」卡上，搬过来时连同措辞
    /// 一起搬——两张卡先后写过同一件事，最怕的就是留下两种说法
    private static func vocabularyPhrase(_ count: Int) -> String {
        tr("词汇表 \(count) 条", "\(count) vocabulary terms")
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

    /// 「自动检测语言 · 模型 0.6B 已就绪 · 麦克风 AirPods Pro」
    ///
    /// 4.1.6 起**这张卡不再提词汇表**：那个框搬去了「输入 → 写作偏好」，卡上还写着条数的话，
    /// 用户会点「更改」进到一页里根本没有词汇表的编辑器。它现在长在「输入」卡上。
    /// - micName: 用户指定的麦克风名；空串 = 跟随系统默认，那就不占一格
    static func recognitionSummary(language: String,
                                   modelState: ModelState,
                                   micName: String) -> Card {
        var parts = [languagePhrase(language)]
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
    ///
    /// **判据是识别引擎本身，不是"选的服务商是不是阿里云"**：4.0.2 这里问的是
    /// `engine == .cloudAlibaba`，于是从 4.0.0 升上来、设置里还存着 `cloudOpenAI` 的人
    /// （那一档仍然是活的，见 CloudASRSettings.currentConfig）在概览上读到的是
    /// 「OpenAI · … · 已连通 ✓」，一个徽章都没有——而他每段录音都在上传。
    /// 这条事实当时只有「云端 AI」页里那行横幅说过，而正因为卡上没有徽章，他不会点进去。
    static func cloudSummary(provider: LLMProvider,
                             model: String,
                             keyState: KeyState,
                             polishLevel: PolishLevel,
                             engine: RecognitionEngineChoice) -> Card {
        guard AISetup.mode(polishLevel: polishLevel, engine: engine) == .withAI else {
            return Card(sentence: tr("未启用 · 只用本地", "Off · on-device only"), badge: nil)
        }
        var parts = [provider.segmentName]
        // 润色关着还落在这一档 = 云端识别开着。这会儿那个润色型号一次都不会被用到，
        // 把它报出来等于让人以为文字正在被润色（编辑页那行 polishOffInMenuBar 说的是同一件事）
        if polishLevel == .off {
            parts.append(tr("润色关着", "Polish off"))
        } else {
            let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { parts.append(name) }
        }
        let stranded = strandedCloudTarget(engine: engine, provider: provider)
        if let target = stranded {
            // 音频其实传给了界面上那一档之外的地方：这一格必须报真正的收信人
            parts.append(tr("录音上传给\(target)", "Audio uploaded to \(target)"))
        } else if engine.isCloud {
            parts.append(tr("云端识别开", "Cloud recognition on"))
        } else {
            parts.append(keyPhrase(keyState))
        }
        // 「上传给一个你没在选的地方」比「还没填 Key」更贵，徽章位归它
        let badge = stranded == nil ? keyBadge(keyState)
                                    : tr("云端识别停在旧档", "Cloud recognition stranded")
        return Card(sentence: parts.joined(separator: dot), badge: badge)
    }

    /// 音频正在往**用户选中的那一档之外**传吗；是的话返回真正的收信人。
    ///
    /// 两种来路，和「云端 AI」页里那两行横幅同源（AISetup.showsStrandedOpenAICloudNotice /
    /// showsStrandedAlibabaCloudNotice）：换走服务商之后留在 OpenAI、或者留在阿里云的识别档
    /// ——那个开关只在"看着的和生效的都是这一家"时才渲染，于是界面上关不掉它。
    private static func strandedCloudTarget(engine: RecognitionEngineChoice,
                                            provider: LLMProvider) -> String? {
        if AISetup.showsStrandedOpenAICloudNotice(engine: engine, provider: provider) {
            return LLMProvider.openai.segmentName
        }
        if AISetup.showsStrandedAlibabaCloudNotice(engine: engine, provider: provider) {
            return LLMProvider.qwen.segmentName
        }
        return nil
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
