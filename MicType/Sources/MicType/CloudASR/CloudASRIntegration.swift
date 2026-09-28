import Foundation
import Network

// MARK: - 云端识别的接线层（Settings ↔ CloudASREngine）
//
// CloudASREngine 自己不读 Settings、不碰钥匙串、失败也不替谁做主（见 CloudASREngine 的三条纪律）。
// 那些决定全在这一层，而且**全写成纯函数**：语言提示怎么来、接入地址怎么定、云端炸了要不要
// 回落本地——每一条都能在单测里钉死，不用真的花钱调云端。
//
// 铁律（用户 2026-09-22 拍板，5.0.0 起；2026-09-28 起只剩 OpenAI 一家）：
//   • 识别**只有云端**一条路（本机 Qwen3-ASR 整条链路已删）；
//   • 5.1.0 起云端也只有 OpenAI 一家（阿里云整档删除，与 iOS L36 同一个决定）；
//   • 录音按秒计费的事实必须当面写清楚；
//   • 云端失败的退路是**同一家的同步接口重试一次**，再失败就如实报错，绝不自动改用户的设置。

// MARK: - 识别引擎档位

/// 这一刻走哪一家的云端识别。**不再是一条设置**（5.0.0 起由 Settings.recognitionEngine
/// 从生效服务商推出来）；留成枚举是因为整条云端链路（配置组装、就绪判定、日志、
/// 设置导入摘要）都按它工作。
enum RecognitionEngineChoice: String, CaseIterable {
    case cloudOpenAI

    /// 5.1.0 起只有一档，任何存量值（含老设置里的 cloudAlibaba）都读成它。
    static func parse(_ raw: String) -> RecognitionEngineChoice { .cloudOpenAI }

    /// 恒真（5.0.0 起识别只有云端）。留着是因为它读起来比 `true` 说明意图。
    var isCloud: Bool { true }

    /// 对应的云端供应商
    var cloudProvider: CloudASRProvider { .openai }

    /// 这一档的名字。界面上没有「识别引擎」选择器，所以这串只出现在日志与诊断信息里。
    var displayName: String { tr("云端 · OpenAI", "Cloud · OpenAI") }
}

// MARK: - Settings → CloudASRConfig

/// 设置 + 钥匙串 → 引擎配置。除了 `currentConfig()` / `hasKey()` 这两个要读全局状态的，
/// 其余全是纯函数。
enum CloudASRSettings {

    // MARK: 语言提示

    /// 词汇表 → 云端的 language_hints。
    ///
    /// 5.0.0 起**没有「识别语言」这条设置了**（用户 2026-09-22 拍板：设置页只做一个决定），
    /// 所以这里只剩原来那条 Auto 的规矩：默认什么都不送；**只有**词汇表里同时有
    /// 中日韩文字和西文词条时才送 ["zh","en"]——那是用户自己的词表在说"这是一场中英夹杂
    /// 的口述"，不是我们替他猜的。
    static func languageHints(vocabulary: [String]) -> [String] {
        let hasCJK = vocabulary.contains { containsCJK($0) }
        let hasLatin = vocabulary.contains { containsLatinLetter($0) }
        return (hasCJK && hasLatin) ? ["zh", "en"] : []
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

    // MARK: 组装

    /// 纯函数版：所有输入都从外面传进来，单测不碰 UserDefaults / 钥匙串
    static func config(vocabulary: [String], apiKey: String) -> CloudASRConfig {
        CloudASRConfig(provider: .openai,
                       languageHints: languageHints(vocabulary: vocabulary),
                       // 词表走 keywords[]（过滤规则在 OpenAITranscribeClient.filteredTerms）
                       vocabulary: vocabulary,
                       apiKey: apiKey)
    }

    /// 当前设置下的配置。5.0.0 起**永远拿得到**（识别只有云端，用哪一家跟着服务商走）；
    /// Key 可能是空串，那由 RecognitionEngineReadiness 在按下热键那一刻当面拦。
    static func currentConfig() -> CloudASRConfig {
        let apiKey = KeychainHelper.loadCloudASRKey(for: .openai) ?? ""
        return config(vocabulary: Settings.shared.vocabularyTerms, apiKey: apiKey)
    }

    /// OpenAI 这一档现在指着的是**官方接口**吗。
    ///
    /// 为什么实时那条路非要这道闸：OpenAI 档的 Base URL 很多人拿来指第三方网关，
    /// 而 `wss://api.openai.com/v1/realtime` 是写死的官方地址——网关用户打开那个开关，
    /// 音频会绕过他自己的网关直接去 OpenAI，这既不是他要的，也可能根本没有额度。
    /// 判据与「请求带 store:false」那句隐私文案同源（LLMClient.usesResponsesAPI），
    /// 同一个事实只判一处。
    static var openAIUsesOfficialEndpoint: Bool {
        LLMClient.usesResponsesAPI(baseURL: Settings.shared.baseURL(for: .openai))
    }

    /// 这一档的 Key 在钥匙串里吗
    static func hasKey(for choice: RecognitionEngineChoice) -> Bool {
        let key = KeychainHelper.loadCloudASRKey(for: choice.cloudProvider) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 这台机器有没有网

/// 5.0.0 起识别、润色、指令三件事全在云端，所以"没网"从一个偶发的失败变成了
/// **按下热键那一刻就该当面说清的状态**——否则用户说完一整段，等来的是一句
/// 看不懂的传输错误，而他要做的事（连上网）和那句话毫无关系。
///
/// 三条纪律：
///   • **拿不准就放行**：监视器还没报过第一次、或者 Network 框架说不清楚时一律算"有网"。
///     误拦一次听写（明明有网却不让录）比误放一次糟得多——误放最多是一句正常的失败提示。
///   • 只读一个布尔，**绝不在按键路径上做同步网络调用**。
///   • 不区分 Wi-Fi / 蜂窝 / 有线：用户要做的事都是一样的。
enum NetworkReachability {

    private static let lock = NSLock()
    private static var online = true
    private static var monitor: NWPathMonitor?

    /// 启动时开一次（AppDelegate）。没开过也不影响正确性——那时 isOnline 恒为 true。
    static func start() {
        lock.lock()
        defer { lock.unlock() }
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let next = path.status != .unsatisfied
            lock.lock()
            let changed = next != online
            online = next
            lock.unlock()
            if changed { Log.info("Network reachability online=\(next)") }
        }
        m.start(queue: DispatchQueue.global(qos: .utility))
        monitor = m
    }

    static var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }

    /// 单测用：直接设定这一位（跑完记得设回 true）
    static func setForTesting(online value: Bool) {
        lock.lock(); online = value; lock.unlock()
    }
}

// MARK: - 开录之前的可用性判定

/// 按下热键这一刻，当前这一档识别引擎能不能开工。
/// 写成枚举 + 纯函数，是因为这几句提示必须**当面说清下一步在哪**，而且要能被单测钉住：
/// 「模型没下载」和「云端没填 Key」指向的是两个完全不同的落点。
enum RecognitionEngineReadiness: Equatable {
    case ready
    /// 钥匙串里没有这一家的 Key——5.0.0 起这一档下**连听写都不能用**（识别也在云端）
    case cloudKeyMissing(CloudASRProvider)
    /// 这台机器这会儿没有网。识别、润色、指令三件事全在云端，没网就是全都做不了，
    /// 而"Key 没填"和"没网"要用户做的事完全不同——混成一句话会把人支去重贴 Key。
    case offline

    /// 当前设置下的就绪状态（读 Settings + 钥匙串）。
    static func current() -> RecognitionEngineReadiness {
        evaluate(choice: Settings.shared.recognitionEngine,
                 hasCloudKey: CloudASRSettings.hasKey(for: Settings.shared.recognitionEngine),
                 online: NetworkReachability.isOnline)
    }

    /// 两个闸门（纯函数，单测钉死）：**先问 Key**。
    /// 没填 Key 的人就算这会儿断网，他要做的第一件事也是去填 Key；
    /// 反过来，Key 好好的人突然按不出字，八成就是网没了。
    static func evaluate(choice: RecognitionEngineChoice,
                         hasCloudKey: Bool, online: Bool) -> RecognitionEngineReadiness {
        guard hasCloudKey else { return .cloudKeyMissing(choice.cloudProvider) }
        return online ? .ready : .offline
    }

    var isReady: Bool { self == .ready }

    /// 悬浮窗上那句话。缺 Key 那一档明确指向设置（胶囊按钮会把设置窗口直接打开）。
    var message: String {
        switch self {
        case .ready:
            return ""
        case .cloudKeyMissing(let provider):
            return tr("还没填\(provider.displayName)的 API Key——听写和指令都要用它",
                      "No API key for \(provider.displayName) yet - dictation and commands both need one")
        case .offline:
            return tr("这台 Mac 现在没有网络，识别要联网才能跑",
                      "This Mac is offline, and recognition needs a connection")
        }
    }

    /// 缺 Key 那一档给一个可点的胶囊（和「去配置」同一套机制）。
    /// 没网那一档不给：设置页上没有任何一个开关能把网接回来。
    var settingsChipLabel: String? {
        switch self {
        case .ready, .offline: return nil
        case .cloudKeyMissing: return tr("去设置", "Open settings")
        }
    }
}

// MARK: - 云端失败之后怎么办

/// 云端识别失败时这一轮该往哪走。**引擎不做这个决定**（它只报失败详情），因为"要不要重试、
/// 怎么跟用户说"是产品决定，不是网络层决定。
///
/// 5.0.0 没有本机模型可回落了，所以退路只剩一条：**整段录音还在内存里，
/// 拿它再走一次同一家的同步接口**（用户 2026-09-22 拍板）。只重试一次——
/// 再失败多半是 Key / 额度 / 网络本身的问题，第三趟只是让用户多等一轮。
enum CloudFallbackDecision: Equatable {
    /// 这一轮还没重试过 → 拿整段音频再走一次同步接口
    case retryOnce
    /// 已经重试过，但云端转出来过几段 → 把这几段交付出去，并说清尾巴没转
    case deliverPartial
    /// 已经重试过、什么都没有 → 照常报错
    case reportFailure

    /// - partialText: 云端已经转出来的文字（可能为空串）
    /// - alreadyRetried: 这一轮已经用同步接口重试过一次了
    static func decide(partialText: String, alreadyRetried: Bool) -> CloudFallbackDecision {
        if !alreadyRetried { return .retryOnce }
        return partialText.isEmpty ? .reportFailure : .deliverPartial
    }

    /// 重试那一下悬浮窗上的提示。原因串来自云端客户端，本来就是双语的。
    static func retryNote(reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = trimmed.count > 120 ? String(trimmed.prefix(120)) : trimmed
        return tr("云端识别失败（\(detail)），正在重试一次",
                  "Cloud recognition failed (\(detail)) - retrying once")
    }

    /// 重试也没成时交给用户的那一句。不报技术细节：他已经等了两趟，
    /// 现在唯一有用的信息是"这一段没了，再说一次"（原因照常进日志）。
    static var retryExhausted: String {
        tr("没识别到，请重试", "Nothing came back - please try again")
    }
}

// MARK: - 连通性探针（粘贴即验证 / 把云端识别开关拨开那一下）

/// 往云端发 1 秒合成音，看这条链路通不通。
///
/// 为什么用合成音而不是只查型号清单：这把 Key 能不能调识别端点，只有真的调一次才验得到。
/// 代价是 1 秒音频的计费（OpenAI 约 $0.0003）。
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
        /// 真正跑通的那个模型（结果行要写出来——"用的哪个型号"是用户最想知道的）
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
    /// - sendSegment: 只给单测用的替身（与 CloudASREngine.sendSegment 同一个口子），不花钱、不上网。
    static func run(config: CloudASRConfig,
                    sendSegment: CloudASREngine.SegmentSender? = nil,
                    completion: @escaping (Result<Outcome, CloudASRFailure>) -> Void) {
        let engine = CloudASREngine(config: config)
        if let sendSegment = sendSegment { engine.sendSegment = sendSegment }
        let started = DispatchTime.now()
        let modelName = OpenAITranscribeClient.defaultModel
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

    /// 云端识别开关旁边那一行结果（纯函数，单测钉住措辞）。
    /// 4.1.4 起这一行不再由一颗按钮触发：把开关拨开那一下就会跑一次（见 CloudRecognitionFields）。
    /// 所以第一句说的是**这个开关现在的意思**——"可用"，而不是"刚才连通过一次"。
    /// 往返毫秒数与真正跑通的型号仍然留着：那正是用户唯一能看见的"这条链路快不快"。
    static func successText(_ outcome: Outcome) -> String {
        var base = tr("云端识别可用 ✓ 往返 \(outcome.milliseconds) 毫秒",
                      "Cloud recognition works ✓ round trip \(outcome.milliseconds) ms")
        if let model = outcome.model, !model.isEmpty {
            base += " · " + model
        }
        guard !outcome.text.isEmpty else { return base }
        return base + tr("，返回：", ", returned: ") + String(outcome.text.prefix(20))
    }

    /// 同一行，外加**实时那条链路通没通**（纯函数，单测钉住措辞）。
    ///
    /// 4.1.7 起「云端识别可用」有两种形态，而两者的体验差着一个数量级：实时是松手就有结果
    /// （0.25 秒，与录音长度无关），录完再传要等一趟与录音长度成正比的上传（71 秒录音 8.6 秒）。
    /// 用户恰恰是在按下这个开关的这一刻最该知道自己买到的是哪一种。
    /// `.inconclusive`（网络抖了 / 超时）**什么都不多说**：把一次抖动写成"这把 Key 不支持实时"
    /// 比不说更糟——他会照着这句话去换 Key。
    static func successText(_ outcome: Outcome, streaming: CloudStreamingProbe.Outcome) -> String {
        let base = successText(outcome)
        switch streaming {
        case .live:
            return base + tr("；边说边传，松手就有结果",
                             "; it streams as you speak, so the text is ready when you let go")
        case .unsupported:
            return base + tr("；这把 Key 不支持实时，录完再传",
                             "; this key has no realtime support, so audio is sent after you finish")
        case .inconclusive:
            return base
        }
    }
}
