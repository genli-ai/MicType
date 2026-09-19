import Foundation

// MARK: - 云端识别引擎（可选，默认永远不启用）
//
// 与 QwenEngine 平级的第二个 SpeechEngine：分段 → 编 WAV → 逐段调云端 → 拼回一整段文本。
// 三条纪律：
// 1. **配置从外面传进来**（CloudASRConfig），引擎本身不读 Settings——单测才能不碰 UserDefaults，
//    集成层（DictationController / SettingsView）稍后负责从 Settings 组装。
// 2. **只记耗时与字节数**，永不记音频、转写文本、Key。
// 3. 取消后不回调（与 LLMClient 同一约定）：用户按 Esc 就是把自己放出来了，不该再弹一句错误。
//
// 失败**不在这里**回落本地引擎：那是集成层的决定（要不要回落、怎么告诉用户）。
// 所以除了 SpeechEngine 要求的那版，另外给了一版带 CloudASRFailure 详情的 transcribeDetailed。

// MARK: 配置

struct CloudASRConfig {
    var provider: CloudASRProvider = .alibaba
    var alibabaModel: AlibabaASRModel = .qwen3Flash
    /// 阿里云的接入主机名。界面上没有"区域"了——这台是 AlibabaHostResolver 试出来并
    /// 记在 qwenResolvedHost 里的那台（或用户自己粘的接入地址）。见 AlibabaEndpoint。
    var host: String = AlibabaEndpoint.defaultHost
    /// 语言提示（阿里云最多 4 个；qwen3 只取第一个）
    var languageHints: [String] = []
    /// 词汇表词条：阿里云走 parameters.vocabulary（权重 4），OpenAI 走 keywords[]
    var vocabulary: [String] = []
    var apiKey: String = ""
    /// ITN（数字/单位规范化）只对中英有效，默认关（MicType 自己有润色层）
    var enableITN: Bool = false

    init(provider: CloudASRProvider = .alibaba,
         alibabaModel: AlibabaASRModel = .qwen3Flash,
         host: String = AlibabaEndpoint.defaultHost,
         languageHints: [String] = [],
         vocabulary: [String] = [],
         apiKey: String = "",
         enableITN: Bool = false) {
        self.provider = provider
        self.alibabaModel = alibabaModel
        self.host = host
        self.languageHints = languageHints
        self.vocabulary = vocabulary
        self.apiKey = apiKey
        self.enableITN = enableITN
    }

    /// 配置 → 对应供应商的客户端
    func makeClient() -> CloudTranscriptionProviding {
        switch provider {
        case .alibaba:
            return AlibabaASRClient(apiKey: apiKey,
                                    model: alibabaModel,
                                    host: host,
                                    vocabulary: vocabulary,
                                    languageHints: languageHints,
                                    enableITN: enableITN)
        case .openai:
            return OpenAITranscribeClient(apiKey: apiKey,
                                          languages: languageHints,
                                          keywords: vocabulary)
        }
    }
}

/// 一整次云端识别的结果（跨所有分段）
struct CloudASRTranscription {
    var text: String
    var segmentCount: Int
    /// 云端回报的计费秒数合计（没有回报就是 nil）
    var billedSeconds: Double?
    /// 第一段识别出的语言（阿里云 3.0 不返回）
    var detectedLanguage: String?
}

// MARK: - 分段文本拼接

/// 云端分段结果的拼接。**故意不自己实现**：本地分段用的是 TextPostProcessor.joinSegments，
/// 两条链路缝出来的文本必须逐字一致（云端失败会原样退回本地重跑一遍，同一段录音在两条路上
/// 拼法不同的话，用户会看到"重试之后空格变了"）。
///
/// 规则本身见 TextPostProcessor.needsSegmentSpace：只有两侧都是中日韩时不加分隔符；
/// 阿拉伯语和西文一样靠空格断词，所以 阿|阿、阿|西、西|西 都是**一个**空格
/// （老实现把阿语当成"不靠空格断词"，会把两个阿语词粘成一个不存在的词）。
enum CloudTextJoiner {

    static func join(_ parts: [String]) -> String {
        TextPostProcessor.joinSegments(parts)
    }
}

// MARK: - 引擎

final class CloudASREngine: SpeechEngine, @unchecked Sendable {

    /// 分段之间带多少字的上文过去（帮云端接住被切开的句子）
    private static let contextTailChars = 120

    private let lock = NSLock()
    private var config: CloudASRConfig
    private var handle: CloudASRHandle?
    /// 分段编码与串行调用都在这条队列上：不占主线程（5 分钟音频编 WAV 也要几十毫秒）
    private let queue = DispatchQueue(label: "mictype.cloudasr", qos: .userInitiated)

    /// 发一段音频出去。默认就是 CloudASRExecutor（唯一碰网络的地方）。
    /// 留成可替换的属性只为一件事：**桥接层的取消语义只有多段流程真跑起来才验得到**
    /// （Esc 之后不再开新段、已转段照常交付、取消优先于失败、段间尾巴传给下一段），
    /// 而那条路上每一段都要上网。单测在这里塞一个假发送器，不花钱、不碰网络。
    /// 只允许在"开工之前"替换（构造完到第一次 transcribe 之间），跑起来之后不再改。
    typealias SegmentSender = (URLRequest, CloudTranscriptionProviding, CloudASRHandle,
                               @escaping (Result<CloudASRSegmentResult, CloudASRFailure>) -> Void) -> Void
    var sendSegment: SegmentSender = { request, provider, handle, completion in
        CloudASRExecutor.send(request: request, provider: provider, handle: handle,
                              completion: completion)
    }

    init(config: CloudASRConfig = CloudASRConfig()) {
        self.config = config
    }

    // MARK: 配置读写（线程安全）

    var currentConfig: CloudASRConfig {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    /// 设置改了就整份换掉（集成层从 Settings + 钥匙串组装）
    func update(config newValue: CloudASRConfig) {
        lock.lock()
        config = newValue
        lock.unlock()
    }

    // MARK: SpeechEngine

    var engineName: String { currentConfig.provider.engineName }

    /// 云端没有"模型文件"概念，可用 = 有 Key
    var isModelAvailable: Bool { currentConfig.makeClient().hasCredentials }

    /// 云端永远不占本机内存
    var isModelLoaded: Bool { false }

    /// 没有模型要加载 —— 空实现（需要预热 TLS 时集成层显式调 prewarm()）
    func preload() {}
    func unloadModel() {}

    /// 录音一开始可以调一次：只热 DNS/TLS 与连接池，**不带 Key**（理由同 LLMClient.prewarm）。
    /// UAE → 云端这条链路上能省下 0.5–1.5s 的首包延迟。
    func prewarm() {
        let cfg = currentConfig
        guard cfg.makeClient().hasCredentials else { return }
        let urlString: String
        switch cfg.provider {
        case .alibaba:
            guard let url = AlibabaASRClient.endpoint(host: cfg.host) else { return }
            urlString = url.absoluteString
        case .openai:
            urlString = OpenAITranscribeClient.endpointString
        }
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request).resume()
    }

    /// 中途取消（Esc）：在飞的请求断掉，后续分段不再发，completion 不再回调
    func cancel() {
        lock.lock()
        let inflight = handle
        handle = nil
        lock.unlock()
        inflight?.cancel()
    }

    /// 简版：只给文本或 MTError，completion 在主线程（集成层之外的老调用点与单测在用）
    func transcribe(samples: [Float], completion: @escaping (Result<String, MTError>) -> Void) {
        transcribeDetailed(samples: samples) { result in
            switch result {
            case .success(let transcription): completion(.success(transcription.text))
            case .failure(let failure): completion(.failure(failure.error))
            }
        }
    }

    /// SpeechEngine 版（v4.0 的分段协议）：每转完一段报一次进度，尾巴没转完也要把
    /// **已经转出来的段**交出去——第 3 段炸了不等于前 2 段没说过（TranscriptionOutcome.isPartial）。
    /// 与本机引擎逐字同义：取消 = 不再开新段，已转好的照常交付（所以这里不沿用
    /// transcribeDetailed「取消后不回调」的约定，那一版是给集成层自己收口用的）。
    ///
    /// language / previousText 与本机引擎同义，只是换成云端的口径：语言锁走 language_hints
    /// （本机是把英文全名拼进 prompt），上文走这一段的 context turn。
    @discardableResult
    func transcribe(samples: [Float],
                    language: String?,
                    previousText: String,
                    onSegment: ((String, Int, Int) -> Void)?,
                    completion: @escaping (TranscriptionOutcome) -> Void) -> TranscriptionHandle {
        let outer = TranscriptionHandle()
        // 下面这几个量只在主线程读写（onSegment 与 completion 都回主线程，取消钩子也把
        // 交付排回主队列），不用加锁。
        // inner 是**这一轮**的句柄：取消只能掐掉自己这一轮，不能走 self.cancel()——
        // 那掐的是引擎当前那一轮，用户已经开始下一次听写时会把新的那一轮误杀
        var inner: CloudASRHandle? = nil
        var joined = ""
        var totalSegments = 1
        var delivered = false
        func deliver(_ outcome: TranscriptionOutcome) {
            guard !delivered else { return }
            delivered = true
            completion(outcome)
        }
        /// 取消这一刻手上的东西照常交出去（已转好的段落不跟着一起扔）
        func cancelledOutcome() -> TranscriptionOutcome {
            TranscriptionOutcome(text: joined,
                                 completedSegments: outer.completedSegments,
                                 totalSegments: max(totalSegments, outer.completedSegments),
                                 failure: nil, cancelled: true)
        }

        // Esc 立刻生效：**同步**掐掉在飞的那一次 HTTP（只有 CloudASRHandle 做得到），
        // 已经转好的段落照常交付。只在 onSegment 里查 outer 的老写法要等下一段转完才停得下来，
        // 那一段照常上传、照常计费（阿里云单段 120s 起步，还可能退避重试一次）。
        outer.setCancelHandler {
            inner?.cancel()
            // 交付**不能**同步做：cancel() 是在 DictationController.cancel() 里调的，
            // 同步收口会抢在它落保底历史、把悬浮窗改成「收尾中…」之前跑完这一轮
            DispatchQueue.main.async { deliver(cancelledOutcome()) }
        }

        inner = transcribeDetailed(samples: samples, language: language, previousText: previousText,
                                   onSegment: { text, index, total in
            joined = text
            totalSegments = total
            outer.noteSegmentCompleted()
            onSegment?(text, index, total)
            // 兜底：取消钩子装好之前（或从别的线程）按下的 Esc，在段间再收一次口
            guard outer.isCancelled else { return }
            inner?.cancel()
            deliver(TranscriptionOutcome(text: joined, completedSegments: index,
                                         totalSegments: total, failure: nil, cancelled: true))
        }) { result in
            switch result {
            case .success(let transcription):
                let count = max(transcription.segmentCount, 1)
                deliver(TranscriptionOutcome(text: transcription.text,
                                             completedSegments: transcription.segmentCount,
                                             totalSegments: count,
                                             failure: nil, cancelled: false))
            case .failure(let failure):
                // **取消优先于失败**：用户按了 Esc 之后这一段才超时/限流失败，那不是"云端炸了"。
                // 报成失败的话集成层会按回落判据（DictationController: usesCloud && failure && !cancelled）
                // 把整段音频重新丢给本机引擎跑一遍——用户明明已经喊停了。
                // 本机引擎那边同义（QwenEngine：取消了就不再开新段，已转段照常交付、不带 failure）。
                guard !outer.isCancelled else {
                    deliver(cancelledOutcome())
                    return
                }
                deliver(TranscriptionOutcome(text: joined,
                                             completedSegments: outer.completedSegments,
                                             totalSegments: max(totalSegments, outer.completedSegments + 1),
                                             failure: failure.error, cancelled: false))
            }
        }
        return outer
    }

    /// 详版：失败时连 retryable / 供应商错误码一起给出去，集成层据此决定要不要回落本地引擎。
    /// completion 在主线程；被 cancel() 之后不回调。返回的句柄也可单独用来取消这一次。
    @discardableResult
    func transcribeDetailed(samples: [Float],
                            language: String? = nil,
                            previousText: String = "",
                            onSegment: ((String, Int, Int) -> Void)? = nil,
                            completion: @escaping (Result<CloudASRTranscription, CloudASRFailure>) -> Void)
        -> CloudASRHandle {
        var cfg = currentConfig
        // 调用方给了显式语言（本机那边是"锁定的英文全名"）就按云端的口径换成 hints。
        // 认不出来的名字 sanitize 会滤掉，那时宁可沿用设置里的 hints，也不送一个云端不认的码
        // （阿里云会直接回 InvalidParameter）。
        if let name = language {
            let hints = CloudASRLanguage.sanitize(hints: [CloudASRLanguage.code(forName: name)])
            if !hints.isEmpty { cfg.languageHints = hints }
        }
        let client = cfg.makeClient()
        let handle = CloudASRHandle()
        lock.lock()
        self.handle = handle
        lock.unlock()

        func finish(_ result: Result<CloudASRTranscription, CloudASRFailure>) {
            DispatchQueue.main.async {
                guard !handle.isCancelled else { return }
                completion(result)
            }
        }

        guard client.hasCredentials else {
            finish(.failure(CloudASRFailure(tr("云端识别还没填 API Key（设置 → AI）",
                                               "Cloud recognition has no API key yet (Settings → AI)"))))
            return handle
        }
        guard !samples.isEmpty else {
            finish(.success(CloudASRTranscription(text: "", segmentCount: 0)))
            return handle
        }

        queue.async { [weak self] in
            guard let self = self, !handle.isCancelled else { return }
            let segments = CloudSegmentPlanner.plan(samples: samples, limits: client.segmentLimits)
            guard !segments.isEmpty else {
                finish(.success(CloudASRTranscription(text: "", segmentCount: 0)))
                return
            }
            let seconds = Double(samples.count) / Double(WAVEncoder.defaultSampleRate)
            Log.info("CloudASR start provider=\(cfg.provider.rawValue) "
                     + "model=\(cfg.provider == .alibaba ? cfg.alibabaModel.rawValue : "gpt-transcribe") "
                     + "host=\(cfg.provider == .alibaba ? AlibabaEndpoint.redacted(cfg.host) : "api.openai.com") "
                     + "seconds=\(String(format: "%.1f", seconds)) segments=\(segments.count)")
            self.run(segmentIndex: 0, segments: segments, samples: samples,
                     config: cfg, client: client, texts: [], contextSeed: previousText,
                     billed: nil, language: nil,
                     handle: handle, started: DispatchTime.now(),
                     onSegment: onSegment, finish: finish)
        }
        return handle
    }

    // MARK: 逐段串行

    /// 一段一段来（云端限流按并发算，串行最省事也最稳）。中间状态全靠参数传递，没有共享可变状态。
    private func run(segmentIndex index: Int,
                     segments: [CloudAudioSegment],
                     samples: [Float],
                     config: CloudASRConfig,
                     client: CloudTranscriptionProviding,
                     texts: [String],
                     // contextSeed：第一段的上文种子（录音中已经定稿、不在这次音频里的那段文字）
                     contextSeed: String,
                     billed: Double?,
                     language: String?,
                     handle: CloudASRHandle,
                     started: DispatchTime,
                     onSegment: ((String, Int, Int) -> Void)?,
                     finish: @escaping (Result<CloudASRTranscription, CloudASRFailure>) -> Void) {
        guard !handle.isCancelled else { return }
        guard index < segments.count else {
            let joined = CloudTextJoiner.join(texts)
            Log.info("CloudASR done segments=\(segments.count) chars=\(joined.count) "
                     + "billedSeconds=\(billed.map { String(format: "%.1f", $0) } ?? "?") "
                     + "ms=\(Log.ms(since: started))")
            finish(.success(CloudASRTranscription(text: joined,
                                                  segmentCount: segments.count,
                                                  billedSeconds: billed,
                                                  detectedLanguage: language)))
            return
        }

        let segment = segments[index]
        let slice = Array(samples[segment.range])
        let wav = WAVEncoder.encode(samples: slice)
        // 词表能走参数的（阿里云 3.0 的 parameters.vocabulary、OpenAI 的 keywords[]）就别再塞进上下文，
        // 400 字的上下文额度留给"上一段的尾巴"
        let vocabularyInContext = config.provider == .alibaba
            && !config.alibabaModel.supportsInlineVocabulary
        // 第一段的上文是调用方给的种子（预转写好的前半段），之后每段接上一段的尾巴
        let previousText = texts.last ?? contextSeed
        let context = CloudASRContext.text(
            vocabulary: config.vocabulary,
            previousTail: CloudASRContext.tail(of: previousText, chars: Self.contextTailChars),
            includeVocabulary: vocabularyInContext)
        Log.info("CloudASR seg=\(index + 1)/\(segments.count) "
                 + "seconds=\(String(format: "%.1f", segment.seconds)) wavBytes=\(wav.count)")

        switch client.makeRequest(wav: wav, seconds: segment.seconds, context: context) {
        case .failure(let failure):
            finish(.failure(failure))
        case .success(let request):
            sendSegment(request, client, handle) { [weak self] result in
                guard let self = self, !handle.isCancelled else { return }
                switch result {
                case .failure(let failure):
                    Log.warn("CloudASR seg=\(index + 1) failed status=\(failure.status) code=\(failure.code ?? "-")")
                    finish(.failure(failure))
                case .success(let segResult):
                    let texts = texts + [segResult.text]
                    // 这一段的成果立刻报上去：长段口述最怕"说了五分钟、屏幕上什么都没有"
                    let snapshot = CloudTextJoiner.join(texts)
                    if let onSegment = onSegment {
                        DispatchQueue.main.async {
                            guard !handle.isCancelled else { return }
                            onSegment(snapshot, index + 1, segments.count)
                        }
                    }
                    // 编下一段的 WAV 是重活：回自己的队列，别占 URLSession 的回调线程
                    self.queue.async {
                        let nextBilled = segResult.billedSeconds.map { (billed ?? 0) + $0 } ?? billed
                        self.run(segmentIndex: index + 1, segments: segments, samples: samples,
                                 config: config, client: client, texts: texts,
                                 contextSeed: contextSeed,
                                 billed: nextBilled, language: language ?? segResult.detectedLanguage,
                                 handle: handle, started: started,
                                 onSegment: onSegment, finish: finish)
                    }
                }
            }
        }
    }
}
