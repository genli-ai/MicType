import Foundation

// MARK: - 云端识别的接线层（Settings ↔ CloudASREngine）
//
// CloudASREngine 自己不读 Settings、不碰钥匙串、失败也不替谁做主（见 CloudASREngine 的三条纪律）。
// 那些决定全在这一层，而且**全写成纯函数**：语言提示怎么来、接入地址怎么定、云端炸了要不要
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

    /// 这一档的名字。4.0.1 起界面上没有「识别引擎」选择器了（云端识别只剩 AI 页上
    /// 阿里云那一个开关），所以这串只出现在设置导入摘要、日志与诊断信息里。
    var displayName: String {
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

    // MARK: 接入地址

    /// 现在该往哪台主机发。**没有"区域"这个概念了**（用户 2026-09-19 拍板）：
    /// 用户粘了接入地址就用它，否则用上一次试通的那台，都没有就用候选表的第一项——
    /// 真正的答案由 AlibabaHostResolver 在验证 Key 时试出来（见 AlibabaEndpoint）。
    static func alibabaHost(pastedHost: String, resolvedHost: String,
                            workspace: String, legacyRegionSlug: String?,
                            apiKey: String) -> String {
        AlibabaEndpoint.candidates(pastedHost: pastedHost, resolvedHost: resolvedHost,
                                   workspace: workspace, legacyRegionSlug: legacyRegionSlug,
                                   apiKey: apiKey).first ?? AlibabaEndpoint.defaultHost
    }

    /// 当前设置下的候选主机表（验证 / 「测试识别」用它逐台试）
    static func currentHostCandidates(apiKey: String) -> [String] {
        let s = Settings.shared
        return AlibabaEndpoint.candidates(pastedHost: s.qwenAPIHost,
                                          resolvedHost: s.qwenResolvedHost,
                                          workspace: s.qwenWorkspaceID,
                                          legacyRegionSlug: s.qwenRegion.regionSlug,
                                          apiKey: apiKey)
    }

    /// 把 Key 里认出来的 WorkspaceId 落盘一次（只在验证 / 探测那一刻调用）。
    ///
    /// 为什么非落盘不可：候选主机里工作空间那几台是**从 Key 的形状**认出来的，而润色那条路
    /// （Settings.qwenBaseURL）手上没有 Key，也不该为此去读钥匙串——不落盘的话，识别把音频
    /// 发去工作空间主机、润色把文字发去 dashscope-intl，两边必有一边 401，而
    /// 「一条主机同时决定两件事」正是这一版要立的规矩（见 AlibabaEndpoint 顶部）。
    /// 已经存着一个就不动：用户/老设置里的那个才是权威。
    static func rememberWorkspace(fromKey key: String) {
        guard Settings.shared.qwenWorkspaceID.isEmpty,
              let workspace = AlibabaEndpoint.workspaceID(fromKey: key) else { return }
        Settings.shared.qwenWorkspaceID = workspace
        Log.info("Qwen workspace remembered from the key shape")
    }

    /// 试通之后记下来：主机 + 那个真的能用的识别模型。正常使用从此一次都不再探测。
    /// 也因此润色/指令的 Base URL 跟着一起对了（同一台主机的 compatible-mode）。
    static func rememberResolution(host: String, model: AlibabaASRModel?) {
        let s = Settings.shared
        if let normalized = AlibabaEndpoint.normalizeHost(host) {
            s.qwenResolvedHost = normalized
            Log.info("Qwen host resolved host=\(AlibabaEndpoint.redacted(normalized))")
        }
        if let model = model, model != s.cloudAlibabaModel {
            Log.info("CloudASR model switched to=\(model.rawValue)")
            s.cloudAlibabaModel = model
        }
    }

    // MARK: 组装

    /// 纯函数版：所有输入都从外面传进来，单测不碰 UserDefaults / 钥匙串
    static func config(provider: CloudASRProvider,
                       alibabaModel: AlibabaASRModel,
                       host: String,
                       recognitionLanguage: String,
                       vocabulary: [String],
                       apiKey: String) -> CloudASRConfig {
        CloudASRConfig(provider: provider,
                       alibabaModel: alibabaModel,
                       host: AlibabaEndpoint.normalizeHost(host) ?? AlibabaEndpoint.defaultHost,
                       languageHints: languageHints(recognitionLanguage: recognitionLanguage,
                                                    vocabulary: vocabulary),
                       // 词表按权重 4 送进热词（权重与过滤规则在 AlibabaASRClient）
                       vocabulary: vocabulary,
                       apiKey: apiKey,
                       // ITN（数字规范化）一律关：MicType 自己有润色层，让云端先改一遍
                       // 只会让保真校验与词表替换对不上账
                       enableITN: false)
    }

    /// 当前设置下的配置。nil = 本地档（这一档没有云端配置可言）。
    /// 4.0.1 起它不再因为"区域没有接入点"而返回 nil：区域这个概念已经没有了。
    static func currentConfig() -> CloudASRConfig? {
        let s = Settings.shared
        guard let provider = s.recognitionEngine.cloudProvider else { return nil }
        let apiKey = KeychainHelper.loadCloudASRKey(for: provider) ?? ""
        return config(provider: provider,
                      alibabaModel: s.cloudAlibabaModel,
                      host: alibabaHost(pastedHost: s.qwenAPIHost,
                                        resolvedHost: s.qwenResolvedHost,
                                        workspace: s.qwenWorkspaceID,
                                        legacyRegionSlug: s.qwenRegion.regionSlug,
                                        apiKey: apiKey),
                      recognitionLanguage: s.recognitionLanguage,
                      vocabulary: s.vocabularyTerms,
                      apiKey: apiKey)
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

    /// 当前设置下的就绪状态（读 Settings + 钥匙串）。听写入口与启动路由共用同一个判据：
    /// 选了云端的人不该在启动时被拽去下载一个他明确决定不下的模型。
    static func current() -> RecognitionEngineReadiness {
        let choice = Settings.shared.recognitionEngine
        return evaluate(choice: choice,
                        localModelAvailable: QwenEngine.shared.isModelAvailable,
                        hasCloudKey: CloudASRSettings.hasKey(for: choice))
    }

    /// 4.0.1 起只剩两个闸门：本地档看模型在不在，云端档看有没有 Key。
    /// 原来还有一个「这个区域没有识别接入点」——区域选择器已经拿掉了（用户拍板），
    /// 接入地址改成 App 自己试，配不出地址这件事不再存在。
    static func evaluate(choice: RecognitionEngineChoice,
                         localModelAvailable: Bool,
                         hasCloudKey: Bool) -> RecognitionEngineReadiness {
        guard let provider = choice.cloudProvider else {
            return localModelAvailable ? .ready : .localModelMissing
        }
        return hasCloudKey ? .ready : .cloudKeyMissing(provider)
    }

    var isReady: Bool { self == .ready }

    /// 悬浮窗上那句话。云端两档都明确指向 设置 → 云端 AI（胶囊按钮会把那一页直接打开）：
    /// 4.0.1 起云端识别的开关和那把 Key 都在那一页上。
    var message: String {
        switch self {
        case .ready:
            return ""
        case .localModelMissing:
            // 与 DictationController 既有文案逐字一致：模型缺失时打开的是引导的下载页
            return tr("识别模型未下载——已为你打开下载页",
                      "Speech model not downloaded - opening the download page")
        case .cloudKeyMissing(let provider):
            return tr("当前用的是\(provider.displayName)，但还没填 API Key（设置 → 云端 AI）",
                      "Cloud recognition (\(provider.displayName)) has no API key yet (Settings → Cloud AI)")
        }
    }

    /// 云端那一档给一个可点的胶囊（和「去配置」同一套机制），本地档沿用旧的下载页跳转
    var settingsChipLabel: String? {
        switch self {
        case .ready, .localModelMissing: return nil
        case .cloudKeyMissing: return tr("去设置", "Open settings")
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
/// 为什么用合成音而不是只查型号清单：模型有没有在控制台开通，只有真的调一次识别端点才验得到。
/// 代价是不到一秒的计费（阿里云 $0.000035/s），界面上会写明这一点。
/// 接入地址是上一步（AlibabaHostResolver）用免费的型号清单定下来的——两件事分开问，
/// 错误信息才说得准。
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
        /// 真正跑通的那个模型（阿里云才有；结果行要写出来——"用的哪个型号"是用户最想知道的）
        let model: String?

        init(milliseconds: Int, text: String, billedSeconds: Double?, model: String? = nil) {
            self.milliseconds = milliseconds
            self.text = text
            self.billedSeconds = billedSeconds
            self.model = model
        }
    }

    /// 失败到底算不算"这把 Key 不能用"。
    /// HTTP 200 已经回来、只是这段音频没识别出字（合成音的正常结果）→ 算通过：
    /// 鉴权、接入地址、模型开通这些要验的事都已经验过了。
    static func isAcceptable(_ failure: CloudASRFailure) -> Bool {
        failure.status == 200 && failure.code == CloudASRFailure.emptyTranscriptCode
    }

    /// 发一次探针。completion 在主线程。engine 由闭包持有到回调为止（探针是一次性的）。
    /// - sendSegment: 只给单测用的替身（与 CloudASREngine.sendSegment 同一个口子）。
    ///   "404 就换 qwen3-asr-flash" 这条回落只有真跑一遍多模型流程才验得到，而那条路要上网。
    static func run(config: CloudASRConfig,
                    sendSegment: CloudASREngine.SegmentSender? = nil,
                    completion: @escaping (Result<Outcome, CloudASRFailure>) -> Void) {
        let engine = CloudASREngine(config: config)
        if let sendSegment = sendSegment { engine.sendSegment = sendSegment }
        let started = DispatchTime.now()
        let modelName = config.provider == .alibaba
            ? config.alibabaModel.rawValue : OpenAITranscribeClient.defaultModel
        engine.transcribeDetailed(samples: toneSamples()) { result in
            // 闭包里显式提一下 engine，保证它活到回调（引擎只被这里强引用）
            _ = engine
            let ms = Log.ms(since: started)
            switch result {
            case .success(let transcription):
                completion(.success(Outcome(milliseconds: ms,
                                            text: transcription.text,
                                            billedSeconds: transcription.billedSeconds,
                                            model: modelName)))
            case .failure(let failure):
                if isAcceptable(failure) {
                    completion(.success(Outcome(milliseconds: ms, text: "", billedSeconds: nil,
                                                model: modelName)))
                } else {
                    Log.warn("CloudASR probe failed provider=\(config.provider.rawValue) "
                             + "model=\(modelName) status=\(failure.status) code=\(failure.code ?? "-")")
                    completion(.failure(failure))
                }
            }
        }
    }

    /// 同一台主机上把模型试一遍：用户选的那个 404（ModelNotFound）就改用 qwen3-asr-flash。
    ///
    /// 为什么必须有这一条：4.0.0 的默认识别模型是 qwen-audio-3.0-asr-flash，
    /// 而它根本不在同步端点上（见 AlibabaASRModel 的注释）——老用户设置里存着这个值，
    /// 光改默认值救不了他们。试通之后 rememberResolution 会把模型改过来，只 404 这一次。
    static func runTryingModels(config: CloudASRConfig,
                                models: [AlibabaASRModel],
                                sendSegment: CloudASREngine.SegmentSender? = nil,
                                completion: @escaping (Result<Outcome, CloudASRFailure>) -> Void) {
        func attempt(_ index: Int) {
            guard index < models.count else {
                completion(.failure(CloudASRFailure(tr("没有可用的识别模型", "No usable speech model"),
                                                    status: 404)))
                return
            }
            var cfg = config
            cfg.alibabaModel = models[index]
            run(config: cfg, sendSegment: sendSegment) { result in
                switch result {
                case .success:
                    completion(result)
                case .failure(let failure):
                    // 只有"这个端点上没有这个模型"才值得换一个模型再试；
                    // 401/403/限流换模型一点用都没有，立刻把真正的原因报出来
                    guard failure.status == 404, index + 1 < models.count else {
                        completion(result)
                        return
                    }
                    Log.info("CloudASR model fallback from=\(models[index].rawValue) "
                             + "to=\(models[index + 1].rawValue) (404)")
                    attempt(index + 1)
                }
            }
        }
        attempt(0)
    }

    /// 「测试识别」按钮上那一行结果（纯函数，单测钉住措辞）
    static func successText(_ outcome: Outcome) -> String {
        var base = tr("云端识别已连通 ✓ 往返 \(outcome.milliseconds) 毫秒",
                      "Cloud recognition reached ✓ round trip \(outcome.milliseconds) ms")
        if let model = outcome.model, !model.isEmpty {
            base += " · " + model
        }
        guard !outcome.text.isEmpty else { return base }
        return base + tr("，返回：", ", returned: ") + String(outcome.text.prefix(20))
    }
}

// MARK: - 「粘贴即验证」/「测试识别」的完整一趟（阿里云）

/// 阿里云这一档验一次 Key 要回答两个问题，而且顺序不能反：
///   1. 这把 Key 属于哪台接入主机？—— GET /compatible-mode/v1/models，不花钱、不传音频。
///   2. 这台主机上哪个识别模型能用？—— 1 秒合成音打识别端点，404 就换 qwen3-asr-flash。
/// 分两步问，错误信息才说得准：4.0.0 把两件事混在一趟里，结果"模型不存在"被报成
/// "区域或 Key 不对"，用户翻了半天 Key。
enum CloudASRSetup {

    struct Success {
        let host: String
        let model: AlibabaASRModel
        let outcome: CloudASRProbe.Outcome
    }

    /// - config: 除了主机与模型之外的其余配置（语言提示、词表…）。
    /// - candidates: 候选主机表（CloudASRSettings.currentHostCandidates）。
    /// completion 在主线程。成功时调用方负责 rememberResolution。
    static func verifyAlibaba(apiKey: String,
                              config: CloudASRConfig,
                              candidates: [String],
                              completion: @escaping (Result<Success, CloudASRFailure>) -> Void) {
        let started = DispatchTime.now()
        Log.info("CloudASR verify start provider=alibaba candidates=\(candidates.count)")
        AlibabaHostResolver.resolve(apiKey: apiKey, candidates: candidates) { hostResult in
            switch hostResult {
            case .failure(let failure):
                Log.warn("CloudASR verify failed at host step status=\(failure.status) "
                         + "code=\(failure.code ?? "-") ms=\(Log.ms(since: started))")
                completion(.failure(failure))
            case .success(let host):
                var cfg = config
                cfg.apiKey = apiKey
                cfg.host = host
                CloudASRProbe.runTryingModels(config: cfg,
                                              models: cfg.alibabaModel.fallbackOrder) { result in
                    switch result {
                    case .success(let outcome):
                        let model = AlibabaASRModel(rawValue: outcome.model ?? "") ?? cfg.alibabaModel
                        Log.info("CloudASR verify ok host=\(AlibabaEndpoint.redacted(host)) "
                                 + "model=\(model.rawValue) ms=\(Log.ms(since: started))")
                        completion(.success(Success(host: host, model: model, outcome: outcome)))
                    case .failure(let failure):
                        Log.warn("CloudASR verify failed host=\(AlibabaEndpoint.redacted(host)) "
                                 + "status=\(failure.status) code=\(failure.code ?? "-") "
                                 + "ms=\(Log.ms(since: started))")
                        completion(.failure(failure))
                    }
                }
            }
        }
    }
}
