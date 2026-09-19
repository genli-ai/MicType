import Foundation

// MARK: - 云端识别的接线层（Settings ↔ CloudASREngine）
//
// CloudASREngine 自己不读 Settings、不碰钥匙串、失败也不替谁做主（见 CloudASREngine 的三条纪律）。
// 那些决定全在这一层，而且**全写成纯函数**：语言提示怎么来、区域怎么映射、云端炸了要不要
// 回落本地——每一条都能在单测里钉死，不用真的花钱调云端。
//
// 铁律（用户拍板，别动）：
//   • 本地识别是默认档，云端是用户**显式**选的；
//   • 选了云端才会有音频离开这台 Mac，按秒计费的事实必须当面写清楚；
//   • 云端失败要有退路（本地模型在就本地重跑），但绝不自动改用户的设置。

// MARK: - 识别引擎档位

/// 设置里存的识别引擎。默认 local——音频不出机那一档永远是默认值。
enum RecognitionEngineChoice: String, CaseIterable {
    case local
    case cloudAlibaba
    case cloudOpenAI

    /// 脏值一律回落本地：一条坏设置绝不能把音频送上云端
    static func parse(_ raw: String) -> RecognitionEngineChoice {
        RecognitionEngineChoice(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .local
    }

    var isCloud: Bool { self != .local }

    /// 对应的云端供应商（本地档没有）
    var cloudProvider: CloudASRProvider? {
        switch self {
        case .local: return nil
        case .cloudAlibaba: return .alibaba
        case .cloudOpenAI: return .openai
        }
    }

    /// 分段控件上的名字（三档并排，写不下长句）
    var segmentName: String {
        switch self {
        case .local: return tr("本地 Qwen3-ASR（默认）", "On-device Qwen3-ASR (default)")
        case .cloudAlibaba: return tr("云端 · 阿里云", "Cloud · Alibaba")
        case .cloudOpenAI: return tr("云端 · OpenAI", "Cloud · OpenAI")
        }
    }
}

// MARK: - Settings → CloudASRConfig

/// 设置 + 钥匙串 → 引擎配置。除了 `currentConfig()` / `hasKey()` 这两个要读全局状态的，
/// 其余全是纯函数。
enum CloudASRSettings {

    // MARK: 语言提示

    /// 识别语言 → 云端的 language_hints。
    ///
    /// 两档，和本机引擎同一套规矩（永远不猜）：
    ///   • 用户显式选了某种语言 → 就送这一个代码；云端不认识这个码（荷兰语、波斯语…）就
    ///     一个提示都不送，让云端自己判——送一个它不认识的码只会被判 InvalidParameter。
    ///   • Auto → 默认什么都不送。**只有**词汇表里同时有中日韩文字和西文词条时才送
    ///     ["zh","en"]：那是用户自己的词表在说"这是一场中英夹杂的口述"，不是我们替他猜的。
    static func languageHints(recognitionLanguage: String, vocabulary: [String]) -> [String] {
        let code = recognitionLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !code.isEmpty, code != "auto" {
            return CloudASRLanguage.sanitize(hints: [code])
        }
        let hasCJK = vocabulary.contains { containsCJK($0) }
        let hasLatin = vocabulary.contains { containsLatinLetter($0) }
        return (hasCJK && hasLatin) ? ["zh", "en"] : []
    }

    /// 选了具体语言时，这条提示云端到底收不收得到。
    ///
    /// 为什么要单独有这个判据：识别语言那张表有 30 种，云端的语言表比它短
    /// （nl / fa / el / ro / hu / mk 不在里面），送一个云端不认识的码只会被判 InvalidParameter，
    /// 所以 sanitize 一律滤掉——**但界面上那句「选了具体语言就作为语言提示送过去」是无条件的**。
    /// 用户挑语言的动机恰恰是"说小语种更稳"，被滤掉的又恰恰全是小语种：提示没送出去、
    /// 云端照常自动检测、界面却说已经送了。所以设置页要按这个判据换一句话。
    /// 「自动」与空值返回 true：那一档本来就不送提示，界面说的就是"交给云端判"。
    static func cloudHintDelivered(recognitionLanguage: String) -> Bool {
        let code = recognitionLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty, code != "auto" else { return true }
        // 走 sanitize 而不是自己查表：与真正送出去的那条路同源，改一处两处一起变
        return !CloudASRLanguage.sanitize(hints: [code]).isEmpty
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value)       // 汉字（含扩展 A）
                || (0xF900...0xFAFF).contains(scalar.value)   // 兼容汉字
                || (0x3040...0x30FF).contains(scalar.value)   // 平假名 / 片假名
        }
    }

    static func containsLatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
        }
    }

    // MARK: 区域

    /// 润色那边的 DashScope 区域 → 云端识别的接入区域。**一个区域设置管两件事**：
    /// 同一把百炼 Key、同一个账号，让用户为"润色"和"识别"各选一次区域只会选出两个不一致的值。
    ///
    /// 返回 nil = 这个区域没有云端识别的接入点（东京 / 香港：识别端只有新加坡、美国、北京三个
    /// 主机）。**绝不悄悄换一个能连上的区域**：Key 是分区域的，换了区域等于把 Key 送到另一个
    /// 账号体系去（和 LLMCatalog.qwenBaseURL 返回 "" 是同一条纪律）。
    static func alibabaRegion(for region: LLMCatalog.QwenRegion) -> AlibabaRegion? {
        switch region {
        case .international, .singapore: return .international   // 两者都是 ap-southeast-1
        case .us: return .us
        case .beijing: return .china                             // cn-beijing
        case .tokyo, .hongkong: return nil
        }
    }

    /// 这一档现在的区域配得出接入点吗（本地档与 OpenAI 档永远为真：它们没有区域概念）
    static func regionSupported(choice: RecognitionEngineChoice,
                                region: LLMCatalog.QwenRegion) -> Bool {
        guard choice == .cloudAlibaba else { return true }
        return alibabaRegion(for: region) != nil
    }

    // MARK: 组装

    /// 纯函数版：所有输入都从外面传进来，单测不碰 UserDefaults / 钥匙串
    static func config(provider: CloudASRProvider,
                       alibabaModel: AlibabaASRModel,
                       region: AlibabaRegion,
                       workspaceID: String,
                       recognitionLanguage: String,
                       vocabulary: [String],
                       apiKey: String) -> CloudASRConfig {
        let workspace = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return CloudASRConfig(provider: provider,
                              alibabaModel: alibabaModel,
                              region: region,
                              workspaceId: workspace.isEmpty ? nil : workspace,
                              languageHints: languageHints(recognitionLanguage: recognitionLanguage,
                                                           vocabulary: vocabulary),
                              // 词表按权重 4 送进热词（权重与过滤规则在 AlibabaASRClient）
                              vocabulary: vocabulary,
                              apiKey: apiKey,
                              // ITN（数字规范化）一律关：MicType 自己有润色层，让云端先改一遍
                              // 只会让保真校验与词表替换对不上账
                              enableITN: false)
    }

    /// 当前设置下的配置。nil = 现在压根配不出来（本地档 / 阿里云区域没有接入点）。
    static func currentConfig() -> CloudASRConfig? {
        let s = Settings.shared
        let choice = s.recognitionEngine
        guard let provider = choice.cloudProvider else { return nil }
        var region = AlibabaRegion.international
        if provider == .alibaba {
            guard let mapped = alibabaRegion(for: s.qwenRegion) else { return nil }
            region = mapped
        }
        return config(provider: provider,
                      alibabaModel: s.cloudAlibabaModel,
                      region: region,
                      workspaceID: s.qwenWorkspaceID,
                      recognitionLanguage: s.recognitionLanguage,
                      vocabulary: s.vocabularyTerms,
                      apiKey: KeychainHelper.loadCloudASRKey(for: provider) ?? "")
    }

    /// 这一档的 Key 在钥匙串里吗（本地档没有 Key 的概念，返回 true）
    static func hasKey(for choice: RecognitionEngineChoice) -> Bool {
        guard let provider = choice.cloudProvider else { return true }
        let key = KeychainHelper.loadCloudASRKey(for: provider) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 开录之前的可用性判定

/// 按下热键这一刻，当前这一档识别引擎能不能开工。
/// 写成枚举 + 纯函数，是因为这几句提示必须**当面说清下一步在哪**，而且要能被单测钉住：
/// 「模型没下载」和「云端没填 Key」指向的是两个完全不同的落点。
enum RecognitionEngineReadiness: Equatable {
    case ready
    /// 本地档但模型没下载
    case localModelMissing
    /// 云端档但钥匙串里没有 Key
    case cloudKeyMissing(CloudASRProvider)
    /// 云端档（阿里云）但当前区域没有识别接入点
    case cloudRegionUnsupported

    /// 当前设置下的就绪状态（读 Settings + 钥匙串）。听写入口与启动路由共用同一个判据：
    /// 选了云端的人不该在启动时被拽去下载一个他明确决定不下的模型。
    static func current() -> RecognitionEngineReadiness {
        let choice = Settings.shared.recognitionEngine
        return evaluate(choice: choice,
                        localModelAvailable: QwenEngine.shared.isModelAvailable,
                        cloudRegionSupported: CloudASRSettings.regionSupported(
                            choice: choice, region: Settings.shared.qwenRegion),
                        hasCloudKey: CloudASRSettings.hasKey(for: choice))
    }

    static func evaluate(choice: RecognitionEngineChoice,
                         localModelAvailable: Bool,
                         cloudRegionSupported: Bool,
                         hasCloudKey: Bool) -> RecognitionEngineReadiness {
        guard let provider = choice.cloudProvider else {
            return localModelAvailable ? .ready : .localModelMissing
        }
        guard cloudRegionSupported else { return .cloudRegionUnsupported }
        return hasCloudKey ? .ready : .cloudKeyMissing(provider)
    }

    var isReady: Bool { self == .ready }

    /// 悬浮窗上那句话。云端两档都明确指向 设置 → 识别（胶囊按钮会把那一页直接打开）。
    var message: String {
        switch self {
        case .ready:
            return ""
        case .localModelMissing:
            // 与 DictationController 既有文案逐字一致：模型缺失时打开的是引导的下载页
            return tr("识别模型未下载——已为你打开下载页",
                      "Speech model not downloaded - opening the download page")
        case .cloudKeyMissing(let provider):
            return tr("当前用的是\(provider.displayName)，但还没填 API Key（设置 → 识别）",
                      "Cloud recognition (\(provider.displayName)) has no API key yet (Settings → Recognition)")
        case .cloudRegionUnsupported:
            return tr("云端识别在当前接入区域没有接入点，请在 设置 → 识别 里改区域",
                      "Cloud recognition has no endpoint in the selected region - change it in Settings → Recognition")
        }
    }

    /// 云端那两档给一个可点的胶囊（和「去配置」同一套机制），本地档沿用旧的下载页跳转
    var settingsChipLabel: String? {
        switch self {
        case .ready, .localModelMissing: return nil
        case .cloudKeyMissing, .cloudRegionUnsupported: return tr("去设置", "Open settings")
        }
    }
}

// MARK: - 云端失败之后怎么办

/// 云端识别失败时这一轮该往哪走。**引擎不做这个决定**（它只报失败详情），因为"要不要回落、
/// 怎么跟用户说"是产品决定，不是网络层决定。
enum CloudFallbackDecision: Equatable {
    /// 本地模型在 → 用本地重跑一遍整段音频（用户一个字都不会丢）
    case retryLocally
    /// 没有本地模型，但云端已经转出来几段 → 把这几段交付出去，并说清尾巴没转
    case deliverPartial
    /// 什么都没有 → 照常报错
    case reportFailure

    /// - partialText: 云端已经转出来的文字（可能为空串）
    /// - localModelAvailable: 本机模型文件在不在（不要求已加载）
    static func decide(partialText: String, localModelAvailable: Bool) -> CloudFallbackDecision {
        if localModelAvailable { return .retryLocally }
        return partialText.isEmpty ? .reportFailure : .deliverPartial
    }

    /// 回落本地之后挂在结果提示里的那句话。原因串来自云端客户端，本来就是双语的。
    static func fallbackNote(reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = trimmed.count > 120 ? String(trimmed.prefix(120)) : trimmed
        return tr("云端识别失败（\(detail)），已改用本地识别",
                  "Cloud recognition failed (\(detail)) - used on-device recognition")
    }
}

// MARK: - 连通性探针（粘贴即验证 / 「测试识别」按钮）

/// 往云端发 1 秒合成音，看这条链路通不通。
///
/// 为什么用合成音而不是 `/models` 那种探活：Key、区域、WorkspaceId、模型有没有在控制台开通——
/// 这四件事只有真的调一次识别端点才全都验得到。代价是不到一秒的计费（阿里云 $0.000035/s），
/// 界面上会写明这一点。
enum CloudASRProbe {

    /// 探针音频：1 秒、440Hz 正弦、半幅。纯函数（可单测），不读任何设置。
    /// 用正弦而不是静音：有些端点对全零音频直接回 400，那验不出 Key 是好是坏。
    static func toneSamples(seconds: Double = 1.0,
                            sampleRate: Int = WAVEncoder.defaultSampleRate,
                            frequency: Double = 440) -> [Float] {
        let count = max(0, Int(seconds * Double(sampleRate)))
        guard count > 0 else { return [] }
        var out = [Float]()
        out.reserveCapacity(count)
        let step = 2 * Double.pi * frequency / Double(sampleRate)
        for i in 0..<count {
            out.append(Float(0.5 * sin(step * Double(i))))
        }
        return out
    }

    struct Outcome {
        /// 整趟往返毫秒数（含分段、编码与网络）
        let milliseconds: Int
        /// 云端转出来的字（合成音多半是空串，这不算失败）
        let text: String
        let billedSeconds: Double?
    }

    /// 失败到底算不算"这把 Key 不能用"。
    /// HTTP 200 已经回来、只是这段音频没识别出字（合成音的正常结果）→ 算通过：
    /// 鉴权、区域、模型开通这些要验的事都已经验过了。
    static func isAcceptable(_ failure: CloudASRFailure) -> Bool {
        failure.status == 200 && failure.code == CloudASRFailure.emptyTranscriptCode
    }

    /// 发一次探针。completion 在主线程。engine 由闭包持有到回调为止（探针是一次性的）。
    static func run(config: CloudASRConfig,
                    completion: @escaping (Result<Outcome, CloudASRFailure>) -> Void) {
        let engine = CloudASREngine(config: config)
        let started = DispatchTime.now()
        engine.transcribeDetailed(samples: toneSamples()) { result in
            // 闭包里显式提一下 engine，保证它活到回调（引擎只被这里强引用）
            _ = engine
            let ms = Log.ms(since: started)
            switch result {
            case .success(let transcription):
                completion(.success(Outcome(milliseconds: ms,
                                            text: transcription.text,
                                            billedSeconds: transcription.billedSeconds)))
            case .failure(let failure):
                if isAcceptable(failure) {
                    completion(.success(Outcome(milliseconds: ms, text: "", billedSeconds: nil)))
                } else {
                    completion(.failure(failure))
                }
            }
        }
    }

    /// 「测试识别」按钮上那一行结果（纯函数，单测钉住措辞）
    static func successText(_ outcome: Outcome) -> String {
        let base = tr("云端识别已连通 ✓ 往返 \(outcome.milliseconds) 毫秒",
                      "Cloud recognition reached ✓ round trip \(outcome.milliseconds) ms")
        guard !outcome.text.isEmpty else { return base }
        return base + tr("，返回：", ", returned: ") + String(outcome.text.prefix(20))
    }
}
