import Foundation

// MARK: - 云端识别供应商（阿里云 Model Studio / OpenAI）
//
// 设计原则：**建请求与解响应全是纯函数**，网络只剩薄薄一层执行器。
// 这样两家的请求体格式、词表过滤、语言提示、错误映射都能在单测里钉死，
// 不用真的花钱调云端；执行器只管发、重试、取消。
//
// 隐私：音频只在用户显式选了云端引擎时才离开这台机器。日志只记字节数与耗时，
// 永不记音频、转写文本、Key。

/// 一次云端识别（可能跨多段请求）的取消句柄。
/// 参照 LLMRequestHandle：cancel() 之后在飞的请求被中断、未发的重试不再发起、completion 不再回调。
/// 这是"云端识别中… 按 Esc 能真把用户放出来"的前提。
final class CloudASRHandle {

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// 返回 false 表示已被取消，调用方不要 resume 这个 task
    @discardableResult
    func adopt(_ newTask: URLSessionDataTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        task = newTask
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let inflight = task
        task = nil
        lock.unlock()
        inflight?.cancel()
    }
}

/// 供应商种类（引擎名、分段上限、Key 存哪个钥匙串账号都由它决定）
enum CloudASRProvider: String, CaseIterable {
    case alibaba
    case openai

    /// SpeechEngine.engineName
    var engineName: String {
        switch self {
        case .alibaba: return "Cloud · Alibaba"
        case .openai: return "Cloud · OpenAI"
        }
    }

    var displayName: String {
        switch self {
        case .alibaba: return tr("云端·阿里云 Qwen ASR", "Cloud · Alibaba Qwen ASR")
        case .openai: return tr("云端·OpenAI", "Cloud · OpenAI")
        }
    }

    var segmentLimits: CloudSegmentLimits {
        switch self {
        case .alibaba: return .alibaba
        case .openai: return .openai
        }
    }

    /// 钥匙串账号：阿里云自己一份，OpenAI 复用润色那把 Key
    var keychainAccount: String {
        switch self {
        case .alibaba: return KeychainHelper.dashScopeAccount
        case .openai: return KeychainHelper.openAIAccount
        }
    }
}

/// 一段音频的识别结果
struct CloudASRSegmentResult: Equatable {
    var text: String
    /// 云端回报的识别语言（阿里云 3.0 不返回；qwen3 / OpenAI 返回）
    var detectedLanguage: String?
    /// 云端计费秒数（用于诊断与成本提示）
    var billedSeconds: Double?

    init(text: String, detectedLanguage: String? = nil, billedSeconds: Double? = nil) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.billedSeconds = billedSeconds
    }
}

/// 一次云端失败：给用户看的话（MTError，双语 + 怎么办）+ 给程序看的判据
struct CloudASRFailure: Error {
    /// 给用户看的双语文案，含"该怎么办"
    let error: MTError
    /// 只有 429 限流 / 5xx / 瞬时网络错误才值得重试一次
    let retryable: Bool
    /// 供应商错误码（InvalidApiKey / insufficient_quota …），本地预校验失败时为 nil
    let code: String?
    /// HTTP 状态码；0 表示还没上网（本地预校验 / 网络层错误）
    let status: Int

    var message: String { error.message }

    /// HTTP 200 回来了、只是这段音频一个字都没识别出来。**这不是一次真正的故障**：
    /// 鉴权、接入地址、模型开通全都通过了。粘贴即验证的探针（CloudASRProbe）据此判"Key 是好的"，
    /// 所以这个码必须稳定，别改字面量。
    static let emptyTranscriptCode = "EmptyTranscript"

    init(_ message: String, retryable: Bool = false, code: String? = nil, status: Int = 0) {
        self.error = MTError(message)
        self.retryable = retryable
        self.code = code
        self.status = status
    }
}

// MARK: - 语言代码

enum CloudASRLanguage {

    /// 两家共同支持的代码（阿里云文档列表；阿拉伯语只有 "ar"，没有方言码）
    static let supported: Set<String> = [
        "zh", "yue", "en", "ja", "de", "ko", "ru", "fr", "pt", "ar", "it", "es", "hi",
        "id", "th", "tr", "uk", "vi", "cs", "da", "fil", "fi", "is", "ms", "no", "pl", "sv",
    ]

    /// enable_itn 只对中英有效
    static let itnSupported: Set<String> = ["zh", "en"]

    /// 规整语言提示：小写、去重、丢掉不认识的码、最多 4 个（阿里云上限）
    static func sanitize(hints: [String], max: Int = 4) -> [String] {
        var out = [String]()
        for raw in hints {
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard supported.contains(code), !out.contains(code) else { continue }
            out.append(code)
            if out.count >= max { break }
        }
        return out
    }

    /// OpenAI 老格式只给语言全名（"english"）→ 尽量折回代码，认不出就原样返回
    static func code(forName name: String) -> String {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if supported.contains(key) { return key }
        return nameToCode[key] ?? key
    }

    private static let nameToCode: [String: String] = [
        "chinese": "zh", "mandarin": "zh", "cantonese": "yue", "english": "en",
        "japanese": "ja", "german": "de", "korean": "ko", "russian": "ru", "french": "fr",
        "portuguese": "pt", "arabic": "ar", "italian": "it", "spanish": "es", "hindi": "hi",
        "indonesian": "id", "thai": "th", "turkish": "tr", "ukrainian": "uk",
        "vietnamese": "vi", "czech": "cs", "danish": "da", "filipino": "fil", "tagalog": "fil",
        "finnish": "fi", "icelandic": "is", "malay": "ms", "norwegian": "no", "polish": "pl",
        "swedish": "sv",
    ]
}

// MARK: - 上下文（热词 / 上一段尾巴）

enum CloudASRContext {

    /// 一条上下文 turn 的字数上限（阿里云文档：≤400 字/turn）
    static let charLimit = 400

    /// 拼上下文：上一段的尾巴（接续用）+ 词汇表（认名词用）。
    /// 两者都没有就返回 nil——宁可不发这个 turn，也不发一个空 turn（空内容容易被判 InvalidParameter）。
    /// includeVocabulary：qwen3 没有独立的 vocabulary 参数，词表只能走上下文；
    /// 3.0 有 parameters.vocabulary，这里就只放尾巴。
    static func text(vocabulary: [String], previousTail: String?, includeVocabulary: Bool,
                     limit: Int = charLimit) -> String? {
        var parts = [String]()
        if includeVocabulary, !vocabulary.isEmpty {
            parts.append("常用词汇：" + vocabulary.joined(separator: "、"))
        }
        if let tail = previousTail?.trimmingCharacters(in: .whitespacesAndNewlines), !tail.isEmpty {
            parts.append("上文：" + tail)
        }
        guard !parts.isEmpty else { return nil }
        var joined = parts.joined(separator: "\n")
        if joined.count > limit { joined = String(joined.suffix(limit)) }
        return joined
    }

    /// 取一段文本的尾巴当下一段的上下文
    static func tail(of text: String, chars: Int = 120) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.suffix(chars))
    }
}

// MARK: - 供应商协议

/// 一家云端识别供应商。建请求 / 解响应 / 映射错误都是纯函数，便于单测；发请求交给 CloudASRExecutor。
protocol CloudTranscriptionProviding {
    var provider: CloudASRProvider { get }
    /// 有没有 Key（没有就等于"引擎不可用"）
    var hasCredentials: Bool { get }
    /// 本地预校验 + 构造请求。失败不上网（体积/时长超限、URL 拼不出来、没 Key）。
    func makeRequest(wav: Data, seconds: Double, context: String?) -> Result<URLRequest, CloudASRFailure>
    /// 解析 HTTP 200 的响应体
    func parse(_ data: Data) -> Result<CloudASRSegmentResult, CloudASRFailure>
    /// 非 200 → 错误映射
    func failure(status: Int, data: Data?) -> CloudASRFailure
}

extension CloudTranscriptionProviding {
    var segmentLimits: CloudSegmentLimits { provider.segmentLimits }
}

// MARK: - 执行器（唯一碰网络的地方）

enum CloudASRExecutor {

    /// 值得重试的瞬时网络错误（与 LLMClient 同一套判据）
    static let retryableURLCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorSecureConnectionFailed,
    ]

    /// 发一段音频。completion 在 URLSession 的回调线程上回调（不保证主线程，调用方自己切）。
    /// 只在 429 限流 / 5xx / 瞬时网络错误时退避重试一次。
    static func send(request: URLRequest,
                     provider: CloudTranscriptionProviding,
                     handle: CloudASRHandle,
                     backoff: TimeInterval = 1.0,
                     retriesLeft: Int = 1,
                     completion: @escaping (Result<CloudASRSegmentResult, CloudASRFailure>) -> Void) {
        guard !handle.isCancelled else { return }
        let started = DispatchTime.now()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            // 取消不是失败：不回调、不重试（悬浮窗不该在用户按了 Esc 之后再弹一句错）
            guard !handle.isCancelled else { return }

            func retryOrFail(_ failure: CloudASRFailure) {
                if failure.retryable, retriesLeft > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + backoff) {
                        send(request: request, provider: provider, handle: handle,
                             backoff: backoff * 2, retriesLeft: retriesLeft - 1, completion: completion)
                    }
                } else {
                    completion(.failure(failure))
                }
            }

            if let error = error {
                let nsError = error as NSError
                if nsError.code == NSURLErrorCancelled { return }
                let transient = retryableURLCodes.contains(nsError.code)
                let text = nsError.code == NSURLErrorTimedOut
                    ? tr("云端识别请求超时（网络到云端太慢）", "Cloud transcription timed out (slow network to the provider)")
                    : tr("云端识别网络错误：", "Cloud transcription network error: ") + error.localizedDescription
                retryOrFail(CloudASRFailure(text, retryable: transient))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(CloudASRFailure(tr("云端没有返回有效响应", "No valid response from the provider"))))
                return
            }
            let bytes = data?.count ?? 0
            Log.info("CloudASR \(provider.provider.rawValue) http=\(http.statusCode) "
                     + "respBytes=\(bytes) ms=\(Log.ms(since: started))")
            guard http.statusCode == 200 else {
                retryOrFail(provider.failure(status: http.statusCode, data: data))
                return
            }
            guard let data = data else {
                completion(.failure(CloudASRFailure(tr("云端返回了空响应体", "Provider returned an empty body"))))
                return
            }
            switch provider.parse(data) {
            case .success(let result): completion(.success(result))
            case .failure(let failure): retryOrFail(failure)
            }
        }
        guard handle.adopt(task) else { return }
        task.resume()
    }
}

// MARK: - 阿里云 Model Studio（DashScope）

/// 两个可选模型。**默认必须是 qwen3-asr-flash**：官方文档里同步端点
/// （/api/v1/services/aigc/multimodal-generation/generation）上只有它；
/// qwen-audio-3.0-asr-flash 属于「非实时语音识别」那条**异步**链路
/// （/api/v1/services/audio/asr/transcription），打同步端点必然 404 ModelNotFound。
/// 4.0.0 把 3.0 设成了默认，于是云端识别对谁都是一次 404 —— 这就是 4.0.1 要修的那个 bug。
///
/// 3.0 仍然留在枚举里：老用户的设置里存着这个 rawValue，读不出来会整档失灵；
/// 而且真遇到 404 时 CloudASRProbe 会自动改用 qwen3 并记住（见 fallbackOrder）。
enum AlibabaASRModel: String, CaseIterable {
    case qwen3Flash = "qwen3-asr-flash"
    case qwenAudio30Flash = "qwen-audio-3.0-asr-flash"

    var displayName: String {
        switch self {
        case .qwen3Flash: return "qwen3-asr-flash" + tr("（推荐）", " (recommended)")
        case .qwenAudio30Flash:
            return "qwen-audio-3.0-asr-flash" + tr("（异步端点专用，多数账号不可用）",
                                                   " (async endpoint only, unavailable on most accounts)")
        }
    }

    /// 有没有 parameters.vocabulary（决定词表走参数还是走上下文）
    var supportsInlineVocabulary: Bool { self == .qwenAudio30Flash }

    /// 试的顺序：先试用户选的那个，404 了再试 qwen3-asr-flash。
    /// 只有这一条回落——它是文档上同步端点唯一保证存在的型号。
    var fallbackOrder: [AlibabaASRModel] {
        self == .qwen3Flash ? [self] : [self, .qwen3Flash]
    }
}

struct AlibabaASRClient: CloudTranscriptionProviding {

    // MARK: 配置

    var apiKey: String
    var model: AlibabaASRModel = .qwen3Flash
    /// 接入主机名（裸主机，不带 scheme 与路径）。由 AlibabaHostResolver 试出来，
    /// 界面上没有"区域"这个概念了——见 AlibabaEndpoint 顶部那段。
    var host: String = AlibabaEndpoint.defaultHost
    /// 词汇表原文（右侧词 + 普通词条），权重统一 4
    var vocabulary: [String] = []
    var languageHints: [String] = []
    /// ITN（数字/单位规范化）只对中英有效；MicType 自己有润色层，默认关
    var enableITN: Bool = false
    var timeout: TimeInterval = 120

    var provider: CloudASRProvider { .alibaba }
    var hasCredentials: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: 硬限制（与 spec 一致）

    /// 单请求 base64 上限 10MB
    static let maxBase64Bytes = 10 * 1024 * 1024
    /// 单请求时长上限 5 分钟
    static let maxSeconds: Double = 300
    /// 端点路径只写一处（AlibabaEndpoint），这里留个别名给老调用点
    static var apiPath: String { AlibabaEndpoint.asrPath }

    /// 热词上限（文档：≤2000 词）
    static let vocabularyCap = 2000
    /// 推荐权重（1–5，4 为推荐值；50 是"超级热词"，这里不用）
    static let vocabularyWeight = 4

    // MARK: 纯函数 · 端点

    static func endpoint(host: String) -> URL? { AlibabaEndpoint.asrURL(host: host) }

    // MARK: 纯函数 · 热词过滤

    /// 按文档规则过滤词表：
    /// • 含非 ASCII 的词条：总字数 ≤15
    /// • 纯 ASCII 词条：空格分隔不超过 7 段
    /// • 去重、去空白、最多 2000 条
    /// 不合规的直接丢掉——整张词表被云端判 InvalidParameter 比少一个词严重得多。
    static func filteredTerms(_ terms: [String], cap: Int = vocabularyCap) -> [String] {
        var out = [String]()
        var seen = Set<String>()
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !seen.contains(term) else { continue }
            guard !term.contains("\n"), !term.contains("\t") else { continue }
            let isASCII = term.unicodeScalars.allSatisfy { $0.isASCII }
            if isASCII {
                let parts = term.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count <= 7 else { continue }
            } else {
                guard term.count <= 15 else { continue }
            }
            seen.insert(term)
            out.append(term)
            if out.count >= cap { break }
        }
        return out
    }

    /// {词: 权重}，供 parameters.vocabulary 直接用
    static func vocabularyParameter(_ terms: [String]) -> [String: Int] {
        var dict = [String: Int]()
        for term in filteredTerms(terms) { dict[term] = vocabularyWeight }
        return dict
    }

    // MARK: 纯函数 · 请求体

    /// 按模型拼请求体。audioDataURI 形如 `data:audio/wav;base64,…`。
    static func requestBody(model: AlibabaASRModel,
                            audioDataURI: String,
                            vocabulary: [String],
                            languageHints: [String],
                            context: String?,
                            enableITN: Bool) -> [String: Any] {
        let hints = CloudASRLanguage.sanitize(hints: languageHints)
        let contextText = context?.trimmingCharacters(in: .whitespacesAndNewlines)
        let audioTurn: [String: Any] = [
            "role": "user",
            "content": [["type": "input_audio", "input_audio": ["data": audioDataURI]]],
        ]

        switch model {
        case .qwenAudio30Flash:
            var messages = [[String: Any]]()
            // 上下文走 input_text + 一个空 assistant turn（文档的 few-shot 形式）。
            // 没有上下文就整对省掉：空 text turn 有被判 InvalidParameter 的风险。
            if let contextText = contextText, !contextText.isEmpty {
                messages.append(["role": "user",
                                 "content": [["type": "input_text", "text": contextText]]])
                messages.append(["role": "assistant",
                                 "content": [["type": "text", "text": ""]]])
            }
            messages.append(audioTurn)
            var parameters: [String: Any] = ["format": "wav", "sample_rate": "16000"]
            let vocab = vocabularyParameter(vocabulary)
            if !vocab.isEmpty { parameters["vocabulary"] = vocab }
            if !hints.isEmpty { parameters["language_hints"] = hints }
            return ["model": model.rawValue,
                    "input": ["messages": messages],
                    "parameters": parameters]

        case .qwen3Flash:
            var messages = [[String: Any]]()
            if let contextText = contextText, !contextText.isEmpty {
                messages.append(["role": "system", "content": [["text": contextText]]])
            }
            messages.append(audioTurn)
            // qwen3 只接受单一语言：取第一个提示；没有就不传（走自动检测）
            var asrOptions: [String: Any] = [:]
            if let first = hints.first { asrOptions["language"] = first }
            let itnOK = enableITN && (hints.first.map { CloudASRLanguage.itnSupported.contains($0) } ?? false)
            asrOptions["enable_itn"] = itnOK
            return ["model": model.rawValue,
                    "input": ["messages": messages],
                    "parameters": ["asr_options": asrOptions]]
        }
    }

    // MARK: 纯函数 · 本地预校验

    /// 上网之前先自查：超限就别发（发了必 400，白等一个 RTT 还可能计费）。
    /// 引擎本来就该先分段，走到这里说明分段参数配错了——报一句明确的话。
    static func precheck(base64Length: Int, seconds: Double) -> CloudASRFailure? {
        if seconds > maxSeconds {
            return CloudASRFailure(tr("这一段音频 ", "This audio segment is ")
                + String(format: "%.0f", seconds)
                + tr("秒，超过云端单请求 5 分钟上限（分段参数有问题，请反馈）",
                     "s long — over the provider's 5-minute per-request limit (segmentation bug, please report)"))
        }
        if base64Length > maxBase64Bytes {
            return CloudASRFailure(tr("这一段音频编码后 ", "This segment encodes to ")
                + String(base64Length / (1024 * 1024))
                + tr("MB，超过云端单请求 10MB 上限（分段参数有问题，请反馈）",
                     "MB — over the provider's 10MB per-request limit (segmentation bug, please report)"))
        }
        return nil
    }

    // MARK: 请求

    func makeRequest(wav: Data, seconds: Double, context: String?) -> Result<URLRequest, CloudASRFailure> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return .failure(CloudASRFailure(tr("还没有填阿里云 API Key（设置 → 云端 AI）",
                                               "No Alibaba API key yet (Settings → Cloud AI)")))
        }
        if let failure = Self.precheck(base64Length: WAVEncoder.base64Length(forByteCount: wav.count),
                                       seconds: seconds) {
            return .failure(failure)
        }
        guard let url = Self.endpoint(host: host) else {
            return .failure(CloudASRFailure(tr("云端接入地址不合法，请重填「接入地址」或清空它让 MicType 自己试",
                                               "The API host is not a valid hostname - re-enter it, or clear it and let MicType find the endpoint")))
        }
        let body = Self.requestBody(model: model,
                                    audioDataURI: WAVEncoder.dataURI(wav: wav),
                                    vocabulary: vocabulary,
                                    languageHints: languageHints,
                                    context: context,
                                    enableITN: enableITN)
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(CloudASRFailure(tr("云端请求体序列化失败", "Could not serialize the request body")))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        // 非流式必须显式关掉 SSE，否则服务端按流式返回、这里解不出来
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        request.httpBody = data
        return .success(request)
    }

    // MARK: 纯函数 · 解析

    func parse(_ data: Data) -> Result<CloudASRSegmentResult, CloudASRFailure> {
        Self.parse(data, model: model)
    }

    static func parse(_ data: Data, model: AlibabaASRModel) -> Result<CloudASRSegmentResult, CloudASRFailure> {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(CloudASRFailure(tr("云端返回格式无法解析", "Could not parse the provider response")))
        }
        // DashScope 有时 HTTP 200 也在 body 里报错
        if let code = json["code"] as? String, !code.isEmpty {
            return .failure(failure(status: 200, code: code, message: json["message"] as? String))
        }
        guard let output = json["output"] as? [String: Any] else {
            return .failure(CloudASRFailure(tr("云端响应缺少 output 字段", "Provider response has no output field")))
        }
        let billed = billedSeconds(json["usage"] as? [String: Any])

        switch model {
        case .qwenAudio30Flash:
            if let text = output["text"] as? String {
                return .success(CloudASRSegmentResult(text: text, billedSeconds: billed))
            }
            // 备用形状：output.sentence.text（也见过 sentence 是数组的）
            if let sentence = output["sentence"] as? [String: Any], let text = sentence["text"] as? String {
                return .success(CloudASRSegmentResult(text: text, billedSeconds: billed))
            }
            if let sentences = output["sentence"] as? [[String: Any]] {
                let text = sentences.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty {
                    return .success(CloudASRSegmentResult(text: text, billedSeconds: billed))
                }
            }
            return .failure(CloudASRFailure(tr("云端没有返回识别文本", "Provider returned no transcript"),
                                            code: CloudASRFailure.emptyTranscriptCode,
                                            status: 200))

        case .qwen3Flash:
            guard let choices = output["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                return .failure(CloudASRFailure(tr("云端没有返回识别文本", "Provider returned no transcript"),
                                                code: CloudASRFailure.emptyTranscriptCode,
                                                status: 200))
            }
            var text: String?
            if let content = message["content"] as? [[String: Any]] {
                let joined = content.compactMap { $0["text"] as? String }.joined()
                text = joined
            } else if let plain = message["content"] as? String {
                text = plain
            }
            guard let text = text else {
                return .failure(CloudASRFailure(tr("云端没有返回识别文本", "Provider returned no transcript"),
                                                code: CloudASRFailure.emptyTranscriptCode,
                                                status: 200))
            }
            var language: String?
            if let annotations = message["annotations"] as? [[String: Any]] {
                for a in annotations where (a["type"] as? String) == "audio_info" {
                    if let lang = a["language"] as? String, !lang.isEmpty { language = lang; break }
                }
            }
            return .success(CloudASRSegmentResult(text: text, detectedLanguage: language, billedSeconds: billed))
        }
    }

    /// 3.0 记在 usage.duration，qwen3 记在 usage.seconds——两个都认
    static func billedSeconds(_ usage: [String: Any]?) -> Double? {
        guard let usage = usage else { return nil }
        for key in ["duration", "seconds"] {
            if let v = usage[key] as? Double { return v }
            if let v = usage[key] as? Int { return Double(v) }
            if let v = usage[key] as? NSNumber { return v.doubleValue }
        }
        return nil
    }

    // MARK: 纯函数 · 错误映射

    func failure(status: Int, data: Data?) -> CloudASRFailure {
        var code: String?
        var message: String?
        if let data = data,
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            code = json["code"] as? String
            message = json["message"] as? String
            // 兼容 OpenAI 风格的 {"error":{...}} 包装
            if code == nil, let err = json["error"] as? [String: Any] {
                code = (err["code"] as? String) ?? (err["type"] as? String)
                message = err["message"] as? String
            }
        }
        return Self.failure(status: status, code: code, message: message)
    }

    /// HTTP 200 的 body 里报上来的错误码 → 它**本该**是的那个状态码。
    /// nil = 这个码我们不认识，照 200 处理（文案会落到"意外状态码"那一条，但至少会写出原码）。
    /// 纯函数，单测钉住每一条映射。
    static func syntheticStatus(code: String) -> Int? {
        let c = code.lowercased()
        if c.contains("datainspection") { return 400 }          // 内容审核拦截 → 那条"可改用本地引擎"
        if c.contains("throttling") { return 429 }              // 限流 → 值得重试那一条
        if c.contains("arrear") { return 403 }                  // 欠费 → 去充值
        if c.contains("invalidapikey") || c.contains("invalidapi-key")
            || c.contains("unauthorized") { return 401 }
        if c.contains("modelnotfound") || c.contains("invalidparameter.model")
            || c.contains("model.not.exist") { return 404 }
        return nil
    }

    /// 状态码 + 错误码 → 双语文案（含"怎么办"）+ 是否值得重试。
    /// 铁律：401 绝不清掉已存的 Key（可能只是接入地址还没试对）。
    /// 每一条都必须给**一句下一步**：屏幕上只写"失败了"等于把排查工作全推给用户。
    static func failure(status: Int, code: String?, message: String?) -> CloudASRFailure {
        let raw = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // DashScope 有时把错误塞在 HTTP 200 的 body 里（parse 会带着 code 走到这里）。
        // 200 这个数字在那种形状下不含任何信息：照着它派发的话，内容审核拦截、限流、
        // Key 不对全都落进最后那条"意外状态码"，一句下一步都没有（违反本段开头那条纪律），
        // 限流还会因为 retryable=false 连那一次重试都不发。所以先按错误码合成一个状态码。
        let effective = status == 200 ? (syntheticStatus(code: raw) ?? status) : status
        // 冒号用 ASCII：这串会直接接在 tail 的 ASCII 括号后面，英文界面下混一个全角「：」
        // 就是一处中文泄漏（CJKUIStringGuardTests 拦的正是 U+FF01–FF60）。中文界面下也不突兀。
        let detail = message.map { ": " + String($0.prefix(80)) } ?? ""
        // status 0 = 还没上网（DNS / 连接失败），"(0)" 对用户没有任何意义，不如不写
        let tail: String = {
            if status == 0 { return raw.isEmpty ? "" : " (" + raw + ")" }
            return " (" + String(status) + (raw.isEmpty ? "" : " " + raw) + ")"
        }()

        func made(_ zh: String, _ en: String, retryable: Bool = false) -> CloudASRFailure {
            // tail 写**真实**的 HTTP 状态码（200 裹着错误码时就写 200 + 那个码），
            // 存进 failure 的却是合成后的那个：下游按它判重试与模型回落
            CloudASRFailure(tr(zh, en) + tail + detail, retryable: retryable, code: raw.isEmpty ? nil : raw,
                            status: effective)
        }

        switch effective {
        case 0:
            return made("连不上阿里云：网络不通，或这个接入地址根本不存在。把百炼控制台里的「接入地址（apiHost）」粘到 设置 → 云端 AI 的「接入地址」里",
                        "Could not reach Alibaba: no network, or that API host does not exist. Paste the API host from the Model Studio console into the API host field in Settings → Cloud AI")
        case 401:
            return made("这把 Key 不属于试过的这些接入地址。到百炼控制台复制「接入地址（apiHost）」，粘到 设置 → 云端 AI 的「接入地址」里；或确认 Key 没有过期",
                        "This key does not belong to any endpoint MicType tried. Copy the API host from the Model Studio console and paste it into the API host field in Settings → Cloud AI, or check that the key is still valid")
        case 403:
            if raw.localizedCaseInsensitiveContains("arrear") {
                return made("阿里云账户欠费，云端识别已停。请充值后再试",
                            "The Alibaba account is in arrears and cloud recognition is blocked. Top it up and try again")
            }
            return made("这个模型还没在阿里云百炼开通（或免费额度已用完、子工作空间无权）。请到百炼控制台 → 模型广场把该模型开通一次",
                        "This model is not enabled for your account (or the free quota is used up, or the sub-workspace lacks access). Enable it once in the Model Studio console → Model Gallery")
        case 404:
            // 别写成"qwen3-asr-flash 也已经试过了"：自动换模型只发生在「测试识别」/ 粘 Key
            // 那一趟上（见 CloudASRProbe.runTryingModels），日常听写这条路不换模型。
            // 说成已经试过，用户就不会再去按那颗真能救他的按钮。
            return made("这个接入地址上没有这个识别模型。请到百炼控制台 → 模型广场开通 qwen3-asr-flash，或在 设置 → 云端 AI 里按一次「测试识别」让 MicType 自动换到它",
                        "This endpoint has no such speech model. Enable qwen3-asr-flash in the Model Studio console → Model Gallery, or hit Test recognition under Settings → Cloud AI so MicType switches to it")
        case 429:
            // 只认 AllocationQuota：Throttling.RateQuota 里也有 "quota" 字样，但那是限流，该重试
            if raw.localizedCaseInsensitiveContains("allocation") {
                return made("云端额度已用完（限额/配额）。请到百炼控制台查看额度，或改用本地引擎",
                            "Cloud quota exhausted. Check your allocation in the Model Studio console, or switch back to the local engine")
            }
            return made("云端限流，已重试一次仍未通过。稍后再说一遍，或改用本地引擎",
                        "Rate limited by the provider (already retried once). Try again shortly or switch back to the local engine",
                        retryable: true)
        case 400:
            if raw.localizedCaseInsensitiveContains("datainspection") {
                return made("云端内容审核拦截了这段音频，识别结果没有返回。可改用本地引擎（音频不出机）",
                            "The provider's content filter blocked this audio, so no transcript came back. The local engine keeps audio on your Mac")
            }
            return made("云端拒绝了这个请求（参数/音频不合规）。若是长录音请分段后重试；反复出现请反馈",
                        "The provider rejected the request (invalid parameter or audio). For long recordings try again in shorter pieces; please report it if it keeps happening")
        default:
            if effective >= 500 {
                return made("云端服务暂时出错，已重试一次。稍后再试，或改用本地引擎",
                            "The provider had a server error (already retried once). Try again later or switch back to the local engine",
                            retryable: true)
            }
            return made("云端返回了意外状态码", "The provider returned an unexpected status code")
        }
    }
}

// MARK: - OpenAI /v1/audio/transcriptions

/// gpt-transcribe（multipart 上传，非流式）。
/// 隐私上这家更好：转写端点不做滥用监控留存、也不留应用状态。
struct OpenAITranscribeClient: CloudTranscriptionProviding {

    var apiKey: String
    /// 型号名写成常量：界面上「已连通 ✓ … · gpt-transcribe」那一行也要用它，别在两处各写一遍
    static let defaultModel = "gpt-transcribe"
    var model: String = defaultModel
    /// languages[]：语言代码（可多个）
    var languages: [String] = []
    /// keywords[]：词汇表词条（相当于热词）
    var keywords: [String] = []
    /// prompt：上一段的尾巴等短上下文
    var prompt: String?
    var timeout: TimeInterval = 300

    var provider: CloudASRProvider { .openai }
    var hasCredentials: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 原始文件上限 25MB（16kHz PCM16 WAV ≈ 781 秒）
    static let maxFileBytes = 25 * 1024 * 1024
    static let endpointString = "https://api.openai.com/v1/audio/transcriptions"
    static let responseFormat = "json"

    // MARK: 纯函数 · multipart

    /// 随机 boundary（单测里可以传固定值，好断言）
    static func makeBoundary() -> String { "MicTypeBoundary" + UUID().uuidString }

    /// 手搓 multipart/form-data。顺序：model → response_format → languages[] → keywords[] → prompt → file。
    /// 文件放最后：服务端边读边解析时，小字段先到手对它更友好。
    static func multipartBody(boundary: String,
                              wav: Data,
                              filename: String = "seg.wav",
                              model: String,
                              languages: [String],
                              keywords: [String],
                              prompt: String?) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data(("--" + boundary + "\r\n").utf8))
            body.append(Data(("Content-Disposition: form-data; name=\"" + name + "\"\r\n\r\n").utf8))
            body.append(Data((value + "\r\n").utf8))
        }
        field("model", model)
        field("response_format", responseFormat)
        for code in CloudASRLanguage.sanitize(hints: languages, max: 4) { field("languages[]", code) }
        for word in AlibabaASRClient.filteredTerms(keywords) { field("keywords[]", word) }
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            field("prompt", prompt)
        }
        body.append(Data(("--" + boundary + "\r\n").utf8))
        body.append(Data(("Content-Disposition: form-data; name=\"file\"; filename=\"" + filename + "\"\r\n").utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n".utf8))
        body.append(Data(("--" + boundary + "--\r\n").utf8))
        return body
    }

    // MARK: 纯函数 · 本地预校验

    static func precheck(fileBytes: Int) -> CloudASRFailure? {
        guard fileBytes > maxFileBytes else { return nil }
        return CloudASRFailure(tr("这一段音频 ", "This segment is ")
            + String(fileBytes / (1024 * 1024))
            + tr("MB，超过 OpenAI 单请求 25MB 上限（分段参数有问题，请反馈）",
                 "MB — over OpenAI's 25MB per-request limit (segmentation bug, please report)"))
    }

    // MARK: 请求

    func makeRequest(wav: Data, seconds: Double, context: String?) -> Result<URLRequest, CloudASRFailure> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return .failure(CloudASRFailure(tr("还没有填 OpenAI API Key（设置 → 云端 AI）",
                                               "No OpenAI API key yet (Settings → Cloud AI)")))
        }
        if let failure = Self.precheck(fileBytes: wav.count) { return .failure(failure) }
        guard let url = URL(string: Self.endpointString) else {
            return .failure(CloudASRFailure(tr("云端地址无效", "Invalid endpoint URL")))
        }
        let boundary = Self.makeBoundary()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.httpBody = Self.multipartBody(boundary: boundary,
                                              wav: wav,
                                              model: model,
                                              languages: languages,
                                              keywords: keywords,
                                              prompt: context ?? prompt)
        return .success(request)
    }

    // MARK: 纯函数 · 解析

    func parse(_ data: Data) -> Result<CloudASRSegmentResult, CloudASRFailure> { Self.parse(data) }

    static func parse(_ data: Data) -> Result<CloudASRSegmentResult, CloudASRFailure> {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(CloudASRFailure(tr("云端返回格式无法解析", "Could not parse the provider response")))
        }
        if let err = json["error"] as? [String: Any] {
            return .failure(failure(status: 200,
                                    code: (err["code"] as? String) ?? (err["type"] as? String),
                                    message: err["message"] as? String))
        }
        guard let text = json["text"] as? String else {
            return .failure(CloudASRFailure(tr("云端没有返回识别文本", "Provider returned no transcript"),
                                            code: CloudASRFailure.emptyTranscriptCode,
                                            status: 200))
        }
        var language: String?
        if let languages = json["languages"] as? [[String: Any]],
           let code = languages.first?["code"] as? String, !code.isEmpty {
            language = code
        } else if let name = json["language"] as? String, !name.isEmpty {
            // verbose_json 老格式给的是语言全名（"english"）→ 折回代码
            language = CloudASRLanguage.code(forName: name)
        }
        return .success(CloudASRSegmentResult(text: text, detectedLanguage: language))
    }

    // MARK: 纯函数 · 错误映射

    func failure(status: Int, data: Data?) -> CloudASRFailure {
        var code: String?
        var message: String?
        if let data = data,
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let err = json["error"] as? [String: Any] {
            code = (err["code"] as? String) ?? (err["type"] as? String)
            message = err["message"] as? String
        }
        return Self.failure(status: status, code: code, message: message)
    }

    static func failure(status: Int, code: String?, message: String?) -> CloudASRFailure {
        let raw = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 冒号用 ASCII：这串会直接接在 tail 的 ASCII 括号后面，英文界面下混一个全角「：」
        // 就是一处中文泄漏（CJKUIStringGuardTests 拦的正是 U+FF01–FF60）。中文界面下也不突兀。
        let detail = message.map { ": " + String($0.prefix(80)) } ?? ""
        let tail = " (" + String(status) + (raw.isEmpty ? "" : " " + raw) + ")"

        func made(_ zh: String, _ en: String, retryable: Bool = false) -> CloudASRFailure {
            CloudASRFailure(tr(zh, en) + tail + detail, retryable: retryable,
                            code: raw.isEmpty ? nil : raw, status: status)
        }

        switch status {
        case 401:
            return made("OpenAI Key 无效或已被吊销。请在 设置 → 云端 AI 里重填（这把 Key 与润色用的是同一把）",
                        "The OpenAI key is invalid or revoked. Re-enter it in Settings → Cloud AI (same key the polish step uses)")
        case 403:
            return made("这把 Key 没有调用该模型的权限。请在 OpenAI 控制台确认项目权限",
                        "This key is not allowed to call the model. Check the project permissions in the OpenAI console")
        case 404:
            return made("OpenAI 找不到这个模型名。请换回默认模型 gpt-transcribe",
                        "OpenAI does not know this model name. Switch back to the default gpt-transcribe")
        case 429:
            if raw.localizedCaseInsensitiveContains("insufficient_quota") {
                return made("OpenAI 账户额度不足，云端识别已停。请充值，或改用本地引擎",
                            "The OpenAI account is out of credit, so cloud recognition is blocked. Add credit or switch back to the local engine")
            }
            return made("OpenAI 限流，已重试一次仍未通过。稍后再说一遍，或改用本地引擎",
                        "Rate limited by OpenAI (already retried once). Try again shortly or switch back to the local engine",
                        retryable: true)
        case 400:
            return made("OpenAI 拒绝了这个请求（参数或文件不合规，最常见是超过 25MB）",
                        "OpenAI rejected the request (invalid parameter or file — most often over the 25MB limit)")
        default:
            if status >= 500 {
                return made("OpenAI 服务暂时出错，已重试一次。稍后再试，或改用本地引擎",
                            "OpenAI had a server error (already retried once). Try again later or switch back to the local engine",
                            retryable: true)
            }
            return made("OpenAI 返回了意外状态码", "OpenAI returned an unexpected status code")
        }
    }
}
