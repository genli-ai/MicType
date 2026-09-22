import Foundation
import Network

// MARK: - 云端识别的接线层（Settings ↔ CloudASREngine）
//
// CloudASREngine 自己不读 Settings、不碰钥匙串、失败也不替谁做主（见 CloudASREngine 的三条纪律）。
// 那些决定全在这一层，而且**全写成纯函数**：语言提示怎么来、接入地址怎么定、云端炸了要不要
// 回落本地——每一条都能在单测里钉死，不用真的花钱调云端。
//
// 铁律（用户 2026-09-22 拍板，5.0.0 起）：
//   • 识别**只有云端**一条路（本机 Qwen3-ASR 整条链路已删）；
//   • 用哪一家不是一条单独的设置，跟着生效服务商走；
//   • 录音按秒计费的事实必须当面写清楚；
//   • 云端失败的退路是**同一家的同步接口重试一次**，再失败就如实报错，绝不自动改用户的设置。

// MARK: - 识别引擎档位

/// 这一刻走哪一家的云端识别。**不再是一条设置**（5.0.0 起由 Settings.recognitionEngine
/// 从生效服务商推出来）；留成枚举是因为整条云端链路（配置组装、就绪判定、日志、
/// 设置导入摘要）都按它工作。
enum RecognitionEngineChoice: String, CaseIterable {
    case cloudAlibaba
    case cloudOpenAI

    /// 脏值回落阿里云那一档只是个形式：调用方拿到的值一律由服务商推出来，
    /// 这条路只剩设置导入摘要在用。
    static func parse(_ raw: String) -> RecognitionEngineChoice {
        RecognitionEngineChoice(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? .cloudAlibaba
    }

    /// 恒真（5.0.0 起识别只有云端）。留着是因为它读起来比 `true` 说明意图。
    var isCloud: Bool { true }

    /// 对应的云端供应商
    var cloudProvider: CloudASRProvider {
        switch self {
        case .cloudAlibaba: return .alibaba
        case .cloudOpenAI: return .openai
        }
    }

    /// 这一档的名字。界面上没有「识别引擎」选择器，所以这串只出现在设置导入摘要、
    /// 日志与诊断信息里。
    var displayName: String {
        switch self {
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

    // MARK: 接入地址

    /// 现在该往哪台主机发。**没有"区域"这个概念了**（用户 2026-09-19 拍板）：
    /// 存着接入地址就用它，否则用上一次试出来的那台，都没有就用候选表的第一项——
    /// 真正的答案由 AlibabaHostResolver 试出来（验证 Key / 失败恢复 / 每周一次的开机复查
    /// 那三条路，见 AlibabaEndpoint）。**日常听写走的就是这里，一句话都不探测。**
    static func alibabaHost(pastedHost: String, resolvedHost: String,
                            workspace: String, legacyRegionSlug: String?,
                            apiKey: String) -> String {
        AlibabaEndpoint.candidates(pastedHost: pastedHost, resolvedHost: resolvedHost,
                                   workspace: workspace, legacyRegionSlug: legacyRegionSlug,
                                   apiKey: apiKey).first ?? AlibabaEndpoint.defaultHost
    }

    /// 当前设置下的候选主机表，**给整表探测用**（验证 Key / 失败恢复 / 开机的周期复查）。
    ///
    /// 与正常听写那一档（alibabaHost）的唯一差别：上一次试出来的那台不占表头。
    /// 4.1.4 之前它钉在第一位，而探测"第一台答应就收工"——于是缓存里种着北京的人
    /// 永远试不到新加坡（见 AlibabaEndpoint 顶部那笔实测）。现在它仍然是候选之一，
    /// 只是要和别人比一次延迟。
    static func currentHostCandidates(apiKey: String) -> [String] {
        let s = Settings.shared
        return AlibabaEndpoint.candidates(pastedHost: s.qwenAPIHost,
                                          resolvedHost: s.qwenResolvedHost,
                                          workspace: s.qwenWorkspaceID,
                                          legacyRegionSlug: s.qwenRegion.regionSlug,
                                          apiKey: apiKey,
                                          pinsResolvedFirst: false)
    }

    /// 试出接入地址。验证 Key、失败恢复、开机复查几条路全走这里。
    ///
    /// **用户自己填了接入地址时，这里只试他那一台，失败就如实报失败**（4.3.1，用户 2026-09-21
    /// 拍板）。4.1.4–4.3.0 是反过来的：那一台 401 / 连不上就把它清掉、回落整表探测——
    /// 当时界面上没有这个输入框，一条死地址真能把人困住。现在框回来了，那条"替他删"
    /// 就成了纯粹的越权：他填的东西必须保持原样，屏幕上说清楚哪儿不通，改不改由他。
    ///
    /// - candidates: 这一趟要试的候选表（正常都传 currentHostCandidates；冒烟测试会指定一台）。
    static func resolveHost(apiKey: String,
                            candidates: [String],
                            completion: @escaping (Result<String, CloudASRFailure>) -> Void) {
        let pinned = AlibabaEndpoint.normalizeHost(Settings.shared.qwenAPIHost) != nil
        AlibabaHostResolver.resolve(apiKey: apiKey, candidates: candidates) { result in
            guard case .failure(let failure) = result else {
                // 刚刚问过整张表了：把时间戳记下来，下次开机的那趟周期复查就不必再问一遍
                //（同一个问题问两次，而每问一次都要把 Key 发给每一台主机）。
                // 填了接入地址的那一趟不算：它只问了一台，不是"挑最快"的那种探测。
                if !pinned { AlibabaFastestHostRefresh.stamp() }
                completion(result)
                return
            }
            // 只试了他指定的那一台，那就别说成"每一个接入地址都不认这把 Key"（那是整表探测的话）。
            // 这一句指回那个输入框——现在它真的在屏幕上（判据与措辞都是纯函数，单测钉死）
            guard pinned,
                  let copy = AlibabaHostResolver.pastedHostFailureCopy(status: failure.status,
                                                                       code: failure.code) else {
                completion(result)
                return
            }
            Log.warn("Qwen pinned host failed host="
                     + AlibabaEndpoint.redacted(Settings.shared.qwenAPIHost)
                     + " status=\(failure.status) code=\(failure.code ?? "-") (kept as entered)")
            completion(.failure(CloudASRFailure(copy, code: failure.code, status: failure.status)))
        }
    }

    /// 云端识别吃了"端点访问被拒"：**后台换一台主机**。
    ///
    /// 为什么识别这条路也要有（4.1.5）：那台主机是 GET /models 验过的，而 2026-09-20 的实测
    /// 证明 /models 通过的主机照样可能把识别端点也一并拒掉（Endpoint.AccessDenied）。
    /// 不换的话，每一段录音都要先白传一趟云端、再回落本机模型——用户只会觉得"云端识别很慢"。
    ///
    /// **这一趟只在后台跑**：本轮录音由 CloudFallbackDecision 交给本机模型，一个字都不丢；
    /// 换好的主机下一段录音才用得上。单飞闸与 60 秒冷却都在 resolveNow 里，
    /// 所以"每台都被拒"的那把 Key 不会变成每句话一趟探测。
    static func recoverIfEndpointDenied(_ failure: CloudASRFailure) {
        // 用户自己填了接入地址：一趟都不探测（与 LLM 那条路同一条规矩，见 AlibabaHostRecovery.action）
        guard AlibabaEndpoint.normalizeHost(Settings.shared.qwenAPIHost) == nil else { return }
        guard Settings.shared.recognitionEngine == .cloudAlibaba,
              AlibabaEndpoint.deniesEndpointAccess(status: failure.status,
                                                   code: failure.code, message: nil) else { return }
        let key = (KeychainHelper.loadCloudASRKey(for: .alibaba) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Log.warn("CloudASR endpoint access denied — re-resolving the host in the background")
        AlibabaHostRecovery.resolveNow(apiKey: key) { changed in
            Log.info("CloudASR host recovery after access denied changed=\(changed)")
        }
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
            // 只有这里写得出"已验证"：这条路的每一个调用方都是**真的联过网**
            //（粘 Key 那一趟、失败后的恢复探测、每周一次的开机复查）。迁移种下的那台不算，
            // 否则它吃 401 时恢复流程一次都不会跑（见 AlibabaEndpoint.hostLooksVerified）。
            s.qwenHostVerified = true
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
                       vocabulary: [String],
                       apiKey: String) -> CloudASRConfig {
        CloudASRConfig(provider: provider,
                       alibabaModel: alibabaModel,
                       host: AlibabaEndpoint.normalizeHost(host) ?? AlibabaEndpoint.defaultHost,
                       languageHints: languageHints(vocabulary: vocabulary),
                       // 词表按权重 4 送进热词（权重与过滤规则在 AlibabaASRClient）
                       vocabulary: vocabulary,
                       apiKey: apiKey,
                       // ITN（数字规范化）一律关：MicType 自己有润色层，让云端先改一遍
                       // 只会让保真校验与词表替换对不上账
                       enableITN: false)
    }

    /// 当前设置下的配置。5.0.0 起**永远拿得到**（识别只有云端，用哪一家跟着服务商走）；
    /// Key 可能是空串，那由 RecognitionEngineReadiness 在按下热键那一刻当面拦。
    static func currentConfig() -> CloudASRConfig {
        let s = Settings.shared
        let provider = s.recognitionEngine.cloudProvider
        let apiKey = KeychainHelper.loadCloudASRKey(for: provider) ?? ""
        return config(provider: provider,
                      alibabaModel: s.cloudAlibabaModel,
                      host: alibabaHost(pastedHost: s.qwenAPIHost,
                                        resolvedHost: s.qwenResolvedHost,
                                        workspace: s.qwenWorkspaceID,
                                        legacyRegionSlug: s.qwenRegion.regionSlug,
                                        apiKey: apiKey),
                      vocabulary: s.vocabularyTerms,
                      apiKey: apiKey)
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

// MARK: - 「这一家这次运行里已经当面验过一次」

/// 只为一件事（4.3.1）：换服务商时云端识别会自动落到新一家上，那一刻要不要再花一秒钱测一遍。
///
/// **内存态、按服务商**：切走又切回来不该每次都测（用户在设置里就是来回点着对比的），
/// 但重启一次就重新测——Key 可能被吊销、额度可能用完，而这两件事我们无从得知。
/// 与 CloudStreamingAvailability 分开：那一份记的是"实时这条链路用不了"（更细，按主机），
/// 这一份记的是"这一家整条云端识别刚刚验过"。
enum CloudRecognitionCheckMemory {

    private static let lock = NSLock()
    private static var checked: Set<String> = []

    static func isChecked(_ provider: CloudASRProvider) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return checked.contains(provider.rawValue)
    }

    static func markChecked(_ provider: CloudASRProvider) {
        lock.lock(); checked.insert(provider.rawValue); lock.unlock()
    }

    /// 验失败了 / Key 换了：忘掉，下次落到这一家时重新测
    static func forget(_ provider: CloudASRProvider) {
        lock.lock(); checked.remove(provider.rawValue); lock.unlock()
    }

    static func resetForTesting() {
        lock.lock(); checked = []; lock.unlock()
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

// MARK: - 「粘贴即验证」/「把云端识别拨开」的完整一趟（阿里云）

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
        CloudASRSettings.resolveHost(apiKey: apiKey, candidates: candidates) { hostResult in
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
