import Foundation

// MARK: - 云端识别供应商（OpenAI）
//
// 设计原则：**建请求与解响应全是纯函数**，网络只剩薄薄一层执行器。
// 这样请求体格式、词表过滤、语言提示、错误映射都能在单测里钉死，
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

/// 供应商种类（引擎名、分段上限、Key 存哪个钥匙串账号都由它决定）。
///
/// 5.1.0 起**只有 OpenAI 一家**（用户 2026-09-28 拍板，与 iOS L36 同一个决定：阿里云整档删除）。
/// 仍然留成枚举：整条云端链路（日志、可用性记忆、分段上限、钥匙串账号）都按它取值，
/// 改成散落的常量只会让"识别用的是哪一家"这件事再也没有一个出处。
enum CloudASRProvider: String, CaseIterable {
    case openai

    /// SpeechEngine.engineName
    var engineName: String { "Cloud · OpenAI" }

    var displayName: String { tr("云端·OpenAI", "Cloud · OpenAI") }

    var segmentLimits: CloudSegmentLimits { .openai }

    /// 钥匙串账号：复用润色那把 Key（听写、润色、指令同一把）
    var keychainAccount: String { KeychainHelper.openAIAccount }
}

/// 一段音频的识别结果
struct CloudASRSegmentResult: Equatable {
    var text: String
    /// 云端回报的识别语言（OpenAI 会返回）
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

    /// 状态码 → 悬浮窗按钮（纯函数）：401 只能去设置里换 Key；额度用完只能去充值；其余只能关掉
    static func action(status: Int, code: String?) -> OverlayErrorAction {
        if status == 401 { return .openSettings }
        if status == 429, (code ?? "").localizedCaseInsensitiveContains("insufficient_quota") {
            return .addCredit
        }
        return .dismiss
    }

    /// - action: 摆到悬浮窗上时带哪颗按钮。**不传就按状态码推**（401 → 打开设置，
    ///   余额不足 → 去充值），缺 Key 那一处自己点名 .openSettings（它没有状态码可推）
    init(_ message: String, retryable: Bool = false, code: String? = nil, status: Int = 0,
         action: OverlayErrorAction? = nil) {
        self.error = MTError(message, action: action ?? CloudASRFailure.action(status: status, code: code))
        self.retryable = retryable
        self.code = code
        self.status = status
    }
}

// MARK: - 语言代码

enum CloudASRLanguage {

    /// 认得的语言代码（阿拉伯语只有 "ar"，没有方言码）
    static let supported: Set<String> = [
        "zh", "yue", "en", "ja", "de", "ko", "ru", "fr", "pt", "ar", "it", "es", "hi",
        "id", "th", "tr", "uk", "vi", "cs", "da", "fil", "fi", "is", "ms", "no", "pl", "sv",
    ]

    /// 规整语言提示：小写、去重、丢掉不认识的码、最多 4 个
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

    /// 上下文（OpenAI 的 prompt 字段）的字数上限
    static let charLimit = 400

    /// 拼上下文：只有上一段的尾巴（接续用）。词汇表不进这里——它走 keywords[]
    /// （5.1.0 之前阿里云 qwen3 没有独立的词表参数，才需要把词表塞进上下文）。
    /// 没有尾巴就返回 nil：宁可不发 prompt，也不发一个空串。
    static func text(previousTail: String?, limit: Int = charLimit) -> String? {
        guard let tail = previousTail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tail.isEmpty else { return nil }
        let joined = "上文：" + tail
        return joined.count > limit ? String(joined.suffix(limit)) : joined
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
    /// 5.1.0 起上传体是 m4a（AAC-LC 48 kbps）或退路 WAV，见 AACEncoder
    func makeRequest(audio: CloudUploadAudio, seconds: Double, context: String?) -> Result<URLRequest, CloudASRFailure>
    /// 解析 HTTP 200 的响应体
    func parse(_ data: Data) -> Result<CloudASRSegmentResult, CloudASRFailure>
    /// 非 200 → 错误映射
    func failure(status: Int, data: Data?) -> CloudASRFailure
}

extension CloudTranscriptionProviding {
    var segmentLimits: CloudSegmentLimits { provider.segmentLimits }

    /// WAV 那条老入口（单测与退路用）：等价于 `makeRequest(audio: .wav(wav), …)`
    func makeRequest(wav: Data, seconds: Double, context: String?) -> Result<URLRequest, CloudASRFailure> {
        makeRequest(audio: .wav(wav), seconds: seconds, context: context)
    }
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
                // 系统那句 localizedDescription 只进日志（可能是另一种语言、也可能很长）
                if nsError.code != NSURLErrorTimedOut {
                    Log.warn("CloudASR network error code=\(nsError.code) "
                             + String(error.localizedDescription.prefix(160)))
                }
                let text = nsError.code == NSURLErrorTimedOut
                    ? UserMessage.recognitionTimedOut : UserMessage.networkError
                retryOrFail(CloudASRFailure(text, retryable: transient))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(CloudASRFailure(UserMessage.emptyResponse)))
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
                completion(.failure(CloudASRFailure(UserMessage.emptyResponse)))
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

    // MARK: 纯函数 · 热词过滤

    /// keywords[] 最多送多少条（沿用 4.x 词表的 2000 条上限；词表再长也不该整张被拒）
    static let keywordCap = 2000

    /// 词表 → keywords[]。规则沿用 4.x 那一套（5.1.0 从已删除的阿里云客户端搬过来，
    /// 单测照旧钉着）：
    /// • 含非 ASCII 的词条：总字数 ≤15
    /// • 纯 ASCII 词条：空格分隔不超过 7 段
    /// • 去重、去空白、最多 2000 条
    /// 不合规的直接丢掉——整张词表被云端判 invalid 比少一个词严重得多。
    static func filteredTerms(_ terms: [String], cap: Int = keywordCap) -> [String] {
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

    // MARK: 纯函数 · multipart

    /// 随机 boundary（单测里可以传固定值，好断言）
    static func makeBoundary() -> String { "MicTypeBoundary" + UUID().uuidString }

    /// 手搓 multipart/form-data。顺序：model → response_format → languages[] → keywords[] → prompt → file。
    /// 文件放最后：服务端边读边解析时，小字段先到手对它更友好。
    /// - filename / contentType: 文件那一段的名字与类型。WAV 是 `seg.wav` / `audio/wav`（默认值，
    ///   与 5.0 逐字节相同）；m4a 是 `audio.m4a` / `audio/mp4`（见 CloudUploadAudio）
    static func multipartBody(boundary: String,
                              wav: Data,
                              filename: String = "seg.wav",
                              contentType: String = "audio/wav",
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
        for word in filteredTerms(keywords) { field("keywords[]", word) }
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            field("prompt", prompt)
        }
        body.append(Data(("--" + boundary + "\r\n").utf8))
        body.append(Data(("Content-Disposition: form-data; name=\"file\"; filename=\"" + filename + "\"\r\n").utf8))
        body.append(Data(("Content-Type: " + contentType + "\r\n\r\n").utf8))
        body.append(wav)
        body.append(Data("\r\n".utf8))
        body.append(Data(("--" + boundary + "--\r\n").utf8))
        return body
    }

    // MARK: 纯函数 · 本地预校验

    static func precheck(fileBytes: Int) -> CloudASRFailure? {
        guard fileBytes > maxFileBytes else { return nil }
        // 真走到这里是分段参数出了 bug：大小进日志，屏幕上一句话
        Log.warn("CloudASR precheck: segment \(fileBytes / (1024 * 1024))MB is over the 25MB limit")
        return CloudASRFailure(UserMessage.audioTooLarge)
    }

    // MARK: 请求

    func makeRequest(audio: CloudUploadAudio, seconds: Double, context: String?) -> Result<URLRequest, CloudASRFailure> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return .failure(CloudASRFailure(UserMessage.keyMissing, action: .openSettings))
        }
        if let failure = Self.precheck(fileBytes: audio.data.count) { return .failure(failure) }
        guard let url = URL(string: Self.endpointString) else {
            return .failure(CloudASRFailure(UserMessage.invalidEndpoint))
        }
        let boundary = Self.makeBoundary()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.httpBody = Self.multipartBody(boundary: boundary,
                                              wav: audio.data,
                                              filename: audio.filename,
                                              contentType: audio.contentType,
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
            return .failure(CloudASRFailure(UserMessage.unreadableResponse))
        }
        if let err = json["error"] as? [String: Any] {
            return .failure(failure(status: 200,
                                    code: (err["code"] as? String) ?? (err["type"] as? String),
                                    message: err["message"] as? String))
        }
        guard let text = json["text"] as? String else {
            return .failure(CloudASRFailure(UserMessage.noTranscript,
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
        // 5.3.0 起屏幕上只有一句话（UX 方案 §3 H）：状态码留在句尾括号里（用户抄给别人问时最值钱），
        // 服务商的错误码与原话进日志——不含用户说的内容，只是服务商那一侧的原因。
        if raw.isEmpty == false || message?.isEmpty == false {
            Log.warn("CloudASR error status=\(status) code=\(raw) message="
                     + String((message ?? "").prefix(200)))
        }

        func made(_ text: String, retryable: Bool = false) -> CloudASRFailure {
            CloudASRFailure(text, retryable: retryable, code: raw.isEmpty ? nil : raw, status: status)
        }

        switch status {
        case 401:
            return made(UserMessage.keyRejected)
        case 403:
            return made(UserMessage.keyNotAllowed(status))
        case 404:
            return made(UserMessage.modelNotFound(status))
        case 429:
            if raw.localizedCaseInsensitiveContains("insufficient_quota") {
                return made(UserMessage.outOfCredit(status))
            }
            return made(UserMessage.rateLimited(status), retryable: true)
        case 400:
            return made(UserMessage.requestRejected(status))
        default:
            if status >= 500 {
                return made(UserMessage.serverError(status), retryable: true)
            }
            return made(UserMessage.serverError(status))
        }
    }
}
