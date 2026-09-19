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
    var alibabaModel: AlibabaASRModel = .qwenAudio30Flash
    var region: AlibabaRegion = .international
    /// 可选：填了就走 {WorkspaceId}.{region}.maas.aliyuncs.com 专属主机
    var workspaceId: String?
    /// 语言提示（阿里云最多 4 个；qwen3 只取第一个）
    var languageHints: [String] = []
    /// 词汇表词条：阿里云走 parameters.vocabulary（权重 4），OpenAI 走 keywords[]
    var vocabulary: [String] = []
    var apiKey: String = ""
    /// ITN（数字/单位规范化）只对中英有效，默认关（MicType 自己有润色层）
    var enableITN: Bool = false

    init(provider: CloudASRProvider = .alibaba,
         alibabaModel: AlibabaASRModel = .qwenAudio30Flash,
         region: AlibabaRegion = .international,
         workspaceId: String? = nil,
         languageHints: [String] = [],
         vocabulary: [String] = [],
         apiKey: String = "",
         enableITN: Bool = false) {
        self.provider = provider
        self.alibabaModel = alibabaModel
        self.region = region
        self.workspaceId = workspaceId
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
                                    region: region,
                                    workspaceId: workspaceId,
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

/// 段与段之间要不要插空格，看两侧的文字系统。
/// 与 DictationController 里"前一个字符是 ASCII 字母才补空格"的既有做法同源：
/// 中日韩 / 阿拉伯语这些不靠空格断词的文字，插空格反而多一道伤口。
enum CloudTextJoiner {

    /// 拼接分段结果：逐段去首尾空白、丢掉空段，按两侧文字系统决定分隔符
    static func join(_ parts: [String]) -> String {
        var out = ""
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if out.isEmpty {
                out = part
                continue
            }
            out += separator(leftEnd: out.last, rightStart: part.first) + part
        }
        return out
    }

    /// 两个相邻字符之间的分隔符：不靠空格断词的文字 → 空串；其余（西文等）→ 一个空格
    static func separator(leftEnd: Character?, rightStart: Character?) -> String {
        guard let left = leftEnd, let right = rightStart else { return "" }
        // 任一侧已经是空白 / 换行 → 不再加
        if left.isWhitespace || right.isWhitespace { return "" }
        // 右侧以标点起头（句读、收尾括号引号）→ 不加空格
        if isTrailingPunctuation(right) { return "" }
        if isNoSpaceScript(left) || isNoSpaceScript(right) { return "" }
        return " "
    }

    /// 不靠空格断词的文字系统：中日韩（含全角标点）与阿拉伯语系
    static func isNoSpaceScript(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x1100...0x11FF,           // 韩文字母
                 0x2E80...0xA4CF,           // 中日韩部首 / 假名 / 汉字 / 注音（含 CJK 标点）
                 0xA960...0xA97F,           // 韩文字母扩展 A
                 0xAC00...0xD7FF,           // 韩文音节
                 0xF900...0xFAFF,           // 兼容汉字
                 0xFE30...0xFE4F,           // 中日韩兼容形式
                 0xFF00...0xFF60,           // 全角形式
                 0xFFE0...0xFFE6,
                 0x20000...0x3FFFF:         // 汉字扩展 B 及以后
                return true
            case 0x0600...0x06FF,           // 阿拉伯语
                 0x0750...0x077F,           // 阿拉伯语补充
                 0x08A0...0x08FF,           // 阿拉伯语扩展 A
                 0xFB50...0xFDFF,           // 阿拉伯语表现形式 A
                 0xFE70...0xFEFF:           // 阿拉伯语表现形式 B
                return true
            default:
                continue
            }
        }
        return false
    }

    /// 只可能贴在左边的标点（西文句读与收尾符号）
    private static func isTrailingPunctuation(_ ch: Character) -> Bool {
        ",.!?;:)]}\"'".contains(ch)
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
            guard let url = AlibabaASRClient.endpoint(region: cfg.region, workspaceId: cfg.workspaceId) else { return }
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
    @discardableResult
    func transcribe(samples: [Float],
                    onSegment: ((String, Int, Int) -> Void)?,
                    completion: @escaping (TranscriptionOutcome) -> Void) -> TranscriptionHandle {
        let outer = TranscriptionHandle()
        // 下面这几个量只在主线程读写（onSegment 与 completion 都回主线程），不用加锁。
        // inner 是**这一轮**的句柄：取消只能掐掉自己这一轮，不能走 self.cancel()——
        // 那掐的是引擎当前那一轮，用户已经开始下一次听写时会把新的那一轮误杀
        var inner: CloudASRHandle?
        var joined = ""
        var totalSegments = 1
        var delivered = false
        func deliver(_ outcome: TranscriptionOutcome) {
            guard !delivered else { return }
            delivered = true
            completion(outcome)
        }

        inner = transcribeDetailed(samples: samples, onSegment: { text, index, total in
            joined = text
            totalSegments = total
            outer.noteSegmentCompleted()
            onSegment?(text, index, total)
            guard outer.isCancelled else { return }
            // 段与段之间才停得下来：掐掉在飞的请求，把已经转好的这几段交付出去
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
                            onSegment: ((String, Int, Int) -> Void)? = nil,
                            completion: @escaping (Result<CloudASRTranscription, CloudASRFailure>) -> Void)
        -> CloudASRHandle {
        let cfg = currentConfig
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
            finish(.failure(CloudASRFailure(tr("云端识别还没填 API Key（设置 → 识别）",
                                               "Cloud recognition has no API key yet (Settings → Recognition)"))))
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
                     + "seconds=\(String(format: "%.1f", seconds)) segments=\(segments.count)")
            self.run(segmentIndex: 0, segments: segments, samples: samples,
                     config: cfg, client: client, texts: [], billed: nil, language: nil,
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
        let context = CloudASRContext.text(
            vocabulary: config.vocabulary,
            previousTail: texts.last.flatMap { CloudASRContext.tail(of: $0, chars: Self.contextTailChars) },
            includeVocabulary: vocabularyInContext)
        Log.info("CloudASR seg=\(index + 1)/\(segments.count) "
                 + "seconds=\(String(format: "%.1f", segment.seconds)) wavBytes=\(wav.count)")

        switch client.makeRequest(wav: wav, seconds: segment.seconds, context: context) {
        case .failure(let failure):
            finish(.failure(failure))
        case .success(let request):
            CloudASRExecutor.send(request: request, provider: client, handle: handle) { [weak self] result in
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
                                 billed: nextBilled, language: language ?? segResult.detectedLanguage,
                                 handle: handle, started: started,
                                 onSegment: onSegment, finish: finish)
                    }
                }
            }
        }
    }
}
