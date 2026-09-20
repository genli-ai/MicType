import Foundation

// MARK: - 阿里云百炼的接入地址（App 自己试出来，用户永远不选「国际站 / 中国站」）
//
// 4.0.0 让用户自己选「接入区域」。实测下来那个选择器是两类故障的共同来源：
//   • 区域选错 → 401，而文案让他去核对 Key，查不到头上；
//   • 北京站 + 工作空间 + 4.0 的默认识别模型 → **404**。
//     （官方文档：同步端点 /api/v1/services/aigc/multimodal-generation/generation 上
//      只有 qwen3-asr-flash；qwen-audio-3.0-asr-flash 属于「非实时语音识别」那条
//      异步链路 /api/v1/services/audio/asr/transcription，打同步端点必然 ModelNotFound。）
//
// 用户 2026-09-19 拍板：**不要区域选择器**。这个文件就是那条规矩的实现——
// 候选地址由 App 自己试，试出来的那一台存进 qwenResolvedHost，往后正常使用一次都不再探测。
//
// 4.1.4 改了"怎么算试出来"（用户 2026-09-20 实测后拍板）：**认这把 Key 的主机里最快的那一台**，
// 不再是"顺序试、第一台答 200 的就收工"。为什么非改不可——用户的 Key 在北京站和新加坡站
// 都认，而候选表把北京排在前面、缓存里又种着北京，于是新加坡一次都没被试过：
// 从 UAE 往北京传一段 25.7 秒的录音（约 1.1 MB base64）要 44.7 秒，同一把 Key 在新加坡站
// 转 63 秒音频只要 6.9 秒。两台都"能用"，可差了一个数量级，而先后顺序纯属表的排法。
//
// 4.1.4 同时拿掉了界面上那个「接入地址（可选）」输入框：一个大多数人看不懂、填错了表现为
// "鉴权失败"的框，价值远不如让 App 自己挑最快的那台。存着的值仍然认（导入设置文件还带着它），
// 但它一旦 401 / 连不上就会被丢掉并交回自动探测——界面上已经没有地方能清空它了，
// 留着就是一条改不掉的坏设置。
//
// 一条主机同时决定两件事：润色/指令走 {host}/compatible-mode/v1，云端识别走
// {host}/api/v1/…。两边同源，改一处两处一起变——这正是 4.0.0 里"两页各选一次区域"
// 想解决却没解决的问题。

enum AlibabaEndpoint {

    /// DashScope 同步识别端点（qwen3-asr-flash 唯一的同步路径）
    static let asrPath = "/api/v1/services/aigc/multimodal-generation/generation"
    /// OpenAI 兼容模式的版本段（润色 / 指令 / 型号清单都挂在它下面）
    static let compatiblePath = "/compatible-mode/v1"

    /// 不带 WorkspaceId 时的两个共享主机（文档只给了这两个）
    static let sharedInternationalHost = "dashscope-intl.aliyuncs.com"
    static let sharedChinaHost = "dashscope.aliyuncs.com"

    /// 工作空间专属主机后缀：{WorkspaceId}.{后缀}
    ///
    /// 这张表必须盖住 4.0.0 那个区域选择器能选的每一档（见 LLMCatalog.QwenRegion）：
    /// 少一条，那一档的老用户升级之后就再也试不到自己真正那台主机，表现是"Key 一直不对"。
    /// **一条都不许删**，哪怕它排在最后。
    ///
    /// 顺序（4.1.4 起，用户 2026-09-20 拍板）：**新加坡在最前**。这个顺序只在两件事上起作用——
    /// 日志里的试探次序，以及两台快得分不出高下（相差 150 ms 以内）时谁胜出——
    /// 但那正是用户这台 Mac 上的那一幕：北京排在前面，于是一把两边都认的 Key 被钉死在北京站，
    /// 而从 UAE 过去慢了一个数量级。真正的答案由延迟决定（见 AlibabaHostResolver.decide）。
    static let workspaceSuffixes = [
        "ap-southeast-1.maas.aliyuncs.com",
        "cn-beijing.maas.aliyuncs.com",
        "ap-northeast-1.maas.aliyuncs.com",
        "cn-hongkong.maas.aliyuncs.com",
        "us-east-1.maas.aliyuncs.com",
    ]

    /// 还什么都没试出来时用的那台（国际站共享主机）。**不是**"猜"：它只是候选表的第一项，
    /// 真正的答案由 AlibabaHostResolver 试出来。
    static let defaultHost = sharedInternationalHost

    // MARK: - 纯函数 · 归一化

    private static let hostAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

    /// 把用户粘进来的任何形态归一成裸主机名。
    /// 控制台会给三种串（apiHost、dashScope URL、openAiCompatible URL），三种都要认——
    /// 让用户自己从 `https://xxx.cn-beijing.maas.aliyuncs.com/api/v1` 里抠出主机名，
    /// 抠错一个字符的表现又是"鉴权失败"，那就等于把 4.0.0 的坑原样搬了一遍。
    /// 返回 nil = 这串不是一个能用的主机名（空、带空格、带中文…），调用方据此当成"没填"。
    static func normalizeHost(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        for scheme in ["https://", "http://"] where s.hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count))
        }
        // 路径、userinfo、端口全部丢掉：主机名之外的部分对拼地址毫无用处
        if let slash = s.firstIndex(of: "/") { s = String(s[s.startIndex..<slash]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[s.startIndex..<colon]) }
        while s.hasSuffix(".") { s = String(s.dropLast()) }
        guard s.count >= 4, s.count <= 253, s.contains(".") else { return nil }
        guard !s.hasPrefix("."), !s.hasPrefix("-"), !s.contains("..") else { return nil }
        guard s.unicodeScalars.allSatisfy({ hostAllowed.contains($0) }) else { return nil }
        return s
    }

    /// 这串像不像一个 WorkspaceId（它会被拼进主机名第一段，乱字符拼出来的地址连 DNS 都不通）。
    /// 字符集必须和 normalizeHost 的那张表对得上（**不含下划线**）：放行一个拼出来
    /// 过不了 normalizeHost 的字符，等于生成三条永远拼不出 URL 的候选，然后静默跳过。
    static func isWorkspaceID(_ raw: String) -> Bool {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count >= 3, id.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 老设置（区域 + WorkspaceId）该种进 `qwenResolvedHost` 的那台主机。
    /// nil = 没有可搬的东西，交给正常的探测流程。
    ///
    /// 只搬"用户明确选过区域"的那几位：国际站是出厂默认，把它种成"已试通"只会让探测
    /// 被白白跳过（见 KeyEntryView 的 .llm 分支）。拼不出合法主机名（WorkspaceId 带下划线、
    /// 或者压根没填）同样不种——种一个连 DNS 都不通的地址比不种更糟。
    static func legacyHostSeed(region: LLMCatalog.QwenRegion, workspaceID: String,
                               pastedHost: String, resolvedHost: String) -> String? {
        guard normalizeHost(pastedHost) == nil, normalizeHost(resolvedHost) == nil else { return nil }
        guard region != .international else { return nil }
        let legacy = LLMCatalog.qwenBaseURL(region: region, workspaceID: workspaceID)
        guard !legacy.isEmpty else { return nil }
        return normalizeHost(legacy)
    }

    /// 存着的这台主机算不算**真的试通过**。4.1.1 的一次性迁移用（见 Settings.applyMigrations）。
    ///
    /// 为什么非分不可：`qwenResolvedHost` 有两个来源——真探测（rememberResolution）与
    /// 4.0.1 那次迁移种下的（legacyHostSeed，从来没联过网）。把种子也当成"已验证"，
    /// 正好复现这一版要消掉的那一幕：Key 属于新加坡工作空间、种下的是北京站，于是每句话
    /// 都 401，而恢复流程因为"地址已经定下来了"一次都不跑，只有去设置页点「验证」才好。
    /// 判据与 legacyHostSeed 同源：只有"用户明确选过区域"的那几档才可能是种子。
    static func hostLooksVerified(resolvedHost: String,
                                  region: LLMCatalog.QwenRegion,
                                  workspaceID: String) -> Bool {
        guard let host = normalizeHost(resolvedHost) else { return false }
        guard region != .international,
              let seed = normalizeHost(LLMCatalog.qwenBaseURL(region: region, workspaceID: workspaceID))
        else { return true }
        return host != seed
    }

    /// 从 Key 里认出 WorkspaceId：工作空间的 Key 长成 `sk-ws-xxxx.<密文>`，
    /// 前半段就是主机名的第一段。**只用来多加一个候选地址**，认错了无非多试一台，
    /// 认对了就省掉用户去控制台抄 WorkspaceId 这一步。
    /// 注意：这里只看 Key 的**前缀形状**，密文部分一个字符都不读、不记、不外泄。
    static func workspaceID(fromKey key: String) -> String? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard k.hasPrefix("sk-ws-") else { return nil }
        let body = k.dropFirst(3)   // 去掉 "sk-"，剩下 "ws-xxxx.<密文>"
        let id = String(body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
        return isWorkspaceID(id) ? id : nil
    }

    /// 候选主机。**第一项是"没试过时先用哪一台"**（正常听写就取它，见 CloudASRSettings.alibabaHost）；
    /// 真要挑哪一台由 AlibabaHostResolver 并发试一遍、按延迟选（见那边的 decide）。
    ///
    /// - pastedHost: 存着的接入地址（4.1.4 起界面上没有这个框了，只可能来自导入的设置文件）。
    ///   **有就只用它**——它是用户/设置文件给的答案，不该拿他的 Key 去试别的主机。
    ///   死了怎么办见 dropsPastedHost：丢掉它，交回下面这张完整的表。
    /// - resolvedHost: 上一次试出来的那台（正常使用时候选表就这一项，不再探测）。
    /// - workspace / apiKey: 工作空间专属主机排在共享主机**前面**——知道 WorkspaceId
    ///   就说明这个账号挂在某个区域端点上，先试它命中率最高（省掉一趟必然 401 的国际站往返；
    ///   UAE→云端这条链路上一趟就是 1–2 秒）。
    /// - legacyRegionSlug: 老设置里的区域（qwenRegion）。界面上已经没有这一项了，
    ///   但老用户选过的那个值仍是最好的排序线索，所以留着当种子。
    /// - pinsResolvedFirst: 把"上一次试出来的那台"放到表头。
    ///   正常使用要（那一档只取第一项），**整表探测不要**（false）：钉在表头的那台会在
    ///   "快得分不出高下"时白捡一个胜出，而 4.1.4 要消掉的正是"缓存里种着北京、
    ///   于是新加坡永远没机会"这一幕。false 时它仍然是候选之一，只是排在自己该在的位置上。
    static func candidates(pastedHost: String = "",
                           resolvedHost: String = "",
                           workspace: String = "",
                           legacyRegionSlug: String? = nil,
                           apiKey: String = "",
                           pinsResolvedFirst: Bool = true) -> [String] {
        if let pinned = normalizeHost(pastedHost) { return [pinned] }

        var out = [String]()
        func add(_ host: String?) {
            guard let h = host, !h.isEmpty, !out.contains(h) else { return }
            out.append(h)
        }
        if pinsResolvedFirst { add(normalizeHost(resolvedHost)) }

        let trimmedWorkspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let ws = isWorkspaceID(trimmedWorkspace) ? trimmedWorkspace.lowercased()
                                                 : workspaceID(fromKey: apiKey)
        if let ws = ws {
            var suffixes = workspaceSuffixes
            if let slug = legacyRegionSlug,
               let i = suffixes.firstIndex(where: { $0.hasPrefix(slug + ".") }) {
                suffixes.insert(suffixes.remove(at: i), at: 0)
            }
            for suffix in suffixes { add(ws + "." + suffix) }
        }
        // 共享主机：国际站在前、中国站在后（与 workspaceSuffixes 同一条理由）
        add(sharedInternationalHost)
        add(sharedChinaHost)
        // 上一次试出来的那台没被上面拼出来过（比如它本来是粘进来的）：仍然要试，
        // 只是不占表头那个位置
        if !pinsResolvedFirst { add(normalizeHost(resolvedHost)) }
        return out
    }

    /// 存着的这条接入地址是**一串拼不出主机名的脏值**吗（空着不算）。
    ///
    /// 它只可能来自导入的设置文件（4.1.4 起界面上没有这个输入框了），而这种值在候选表里
    /// 会被静默跳过——用户看不见它、改不了它，日志和错误信息却都绕着它打转。直接丢掉最省事，
    /// 而且什么都不必告诉用户：他本来就没填过。
    static func storedHostIsJunk(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && normalizeHost(raw) == nil
    }

    /// 存着的那条接入地址该不该**丢掉、交回自动探测**。
    ///
    /// 4.1.4 起界面上没有那个输入框了（用户 2026-09-20 拍板），所以一条坏掉的地址会变成
    /// 一条**改不掉的设置**：候选表只剩它一台，每句话 401，而屏幕上没有任何地方能把它清掉。
    /// 两种该丢：
    ///   • 拼不出主机名的脏值——任何时候都该丢（见 storedHostIsJunk）；
    ///   • 401（这把 Key 不属于它）与 status 0（DNS / 连接都不通）。
    /// 403 / 404 / 429 / 5xx **不丢**——那几种恰恰说明主机是对的（鉴权过了、或者只是这一刻不行），
    /// 丢掉它反而把用户送去一台他没指定的主机。
    static func dropsPastedHost(pastedHost: String, status: Int) -> Bool {
        guard !pastedHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard normalizeHost(pastedHost) != nil else { return true }
        return status == 401 || status == 0
    }

    // MARK: - 纯函数 · 拼地址

    /// 云端识别端点
    static func asrURL(host: String) -> URL? {
        guard let h = normalizeHost(host) else { return nil }
        return URL(string: "https://" + h + asrPath)
    }

    /// 润色 / 指令的 Base URL（OpenAI 兼容模式）
    static func compatibleBaseURL(host: String) -> String {
        guard let h = normalizeHost(host) else { return "" }
        return "https://" + h + compatiblePath
    }

    /// 型号清单端点：探测主机用它——不花钱、不上传音频，只回答"这把 Key 是不是这台主机的"
    static func modelsURL(host: String) -> URL? {
        guard let h = normalizeHost(host) else { return nil }
        return URL(string: "https://" + h + compatiblePath + "/models")
    }

    /// 写进日志 / 诊断信息前先把 WorkspaceId 抹掉：主机名第一段就是工作空间编号，
    /// 而诊断信息是要被整段贴出来的（和 Log.startup 不记显示器名字同一条理由）。
    static func redacted(_ host: String) -> String {
        guard host.hasSuffix(".maas.aliyuncs.com"), let dot = host.firstIndex(of: ".") else {
            return host
        }
        return "***" + host[dot...]
    }
}

// MARK: - 请求失败之后：要不要先把接入地址试出来

/// 润色 / 指令打在一台**从来没验证过**的阿里云主机上、吃了 401 或者连 DNS 都不通时该做什么。
///
/// 为什么非有这一层不可（用户 2026-09-20 的测试日志）：Key 属于新加坡工作空间，
/// 而出厂种下的那台是北京站。用户按「验证」之前，润色已经往北京站发过两趟，各等了 33 秒
/// 才报超时——App 手上明明有一套能在 30 秒内把正确主机试出来的机制（AlibabaHostResolver），
/// 却只在设置页点「验证」时才跑。真实使用路径上撞了墙也不去试，等于把排查工作全推给用户。
///
/// 为什么分成「后台试」和「试完重发」两档：润色的全部价值是**顺手**。
/// 让它等一趟 30 秒的探测再重发一遍，比原来那 33 秒还糟——所以润色这一档
/// 当场把识别原文交出去（带既有的那句提醒），探测在后台跑完、把主机记下来，
/// 下一句话就对了。指令是按住说出来的、低频、用户本来就在等结果，那一档才值得等。
enum AlibabaHostRecovery {

    enum Action: Equatable {
        /// 跟接入地址没关系（或已经试过了），照常报错
        case none
        /// 探测照跑，但这一趟当场失败——润色不能再加等待
        case resolveInBackground
        /// 等探测出结果，再原样重发一次
        case resolveAndRetry
    }

    /// 值得触发探测的网络层错误码：主机名解析不了 / 连不上。
    /// **超时不在内**——超时说明这台主机是存在的，只是链路慢，换一台解决不了，
    /// 白白再花 30 秒探测只会让等待更长。
    static let triggeringURLCodes: Set<Int> = [
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorCannotConnectToHost,
    ]

    /// 纯函数，单测钉住每一档。
    /// - isAlibaba: 这一趟发给的是阿里云那一档（别家没有"主机要自己试"这回事）
    /// - hostSettled: 接入地址已经定下来了——用户自己粘过，或上一次真的试通过。
    ///   定下来的主机吃 401 是另一回事（Key 过期 / 被删），再试一圈也只会得到同样的 401。
    /// - canWaitForResolve: 这一趟等得起那 30 秒吗（润色等不起，见上面）
    /// - status: HTTP 状态码；0 = 还没上网
    /// - urlErrorCode: 网络层错误码（NSURLError*），没有就传 nil
    static func action(isAlibaba: Bool,
                       hostSettled: Bool,
                       canWaitForResolve: Bool,
                       status: Int,
                       urlErrorCode: Int?,
                       attemptsLeft: Int) -> Action {
        guard isAlibaba, attemptsLeft > 0, !hostSettled else { return .none }
        let triggered = status == 401
            || (status == 0 && (urlErrorCode.map { triggeringURLCodes.contains($0) } ?? false))
        guard triggered else { return .none }
        return canWaitForResolve ? .resolveAndRetry : .resolveInBackground
    }

    // MARK: 单飞闸

    private static let lock = NSLock()
    private static var inFlight = false
    private static var failedAt: Date?
    /// 正在飞的那一趟还没落地时又撞墙的那些调用（长按说一段话 = 润色、指令前后脚各一趟）。
    /// 4.1.1 最初这一档当场收一个 false，于是指令报的是"API Key 无效"——而那一趟探测
    /// 通常几秒后就把主机试对了。让它们等同一个结果，比各自去撞同一堵墙诚实。
    private static var waiting: [(Bool) -> Void] = []

    /// 刚失败过就先别再试。Key 本身是废的时候，逐台试必然一台台全 401——
    /// 那趟最长 30 秒，而每一次指令都去走一遍等于给每句话都加半分钟。
    /// 冷却期里照常把真正的错误（401 那句"这把 Key 不属于试过的这些接入地址"）报给用户。
    static let failureCooldown: TimeInterval = 60

    /// 这一趟该怎么办。为什么要这道闸：长按说一段话会连着触发润色与指令，两趟同时撞墙
    /// 就会同时各起一趟逐台试的探测——同一把 Key 在 UAE 这条链路上被无谓地多发十几个请求。
    enum Claim: Equatable {
        /// 这一趟自己去试
        case start
        /// 已经有一趟在飞了：搭它的车，结果出来一起收
        case joined
        /// 刚失败过（冷却期内）：别试，当面报原来那个错
        case refused
    }

    /// 领一趟探测，或者搭上正在飞的那一趟。waiter 只有 .joined 那一档会被记下来。
    static func claim(_ waiter: @escaping (Bool) -> Void, now: Date = Date()) -> Claim {
        lock.lock()
        defer { lock.unlock() }
        if inFlight {
            waiting.append(waiter)
            return .joined
        }
        if let failedAt = failedAt, now.timeIntervalSince(failedAt) < failureCooldown { return .refused }
        inFlight = true
        return .start
    }

    /// 领一趟探测。返回 false = 已经有一趟在飞了、或者刚失败过，别再发第二趟。
    static func beginResolve(now: Date = Date()) -> Bool {
        claim({ _ in }, now: now) == .start
    }

    /// 把结论发给搭车的那几趟（主线程，与 resolveNow 的 completion 同一条队）
    private static func notifyWaiting(_ changed: Bool) {
        lock.lock()
        let pending = waiting
        waiting = []
        lock.unlock()
        guard !pending.isEmpty else { return }
        Log.info("Qwen host recovery fanned out to \(pending.count) waiting request(s) changed=\(changed)")
        DispatchQueue.main.async { pending.forEach { $0(changed) } }
    }

    static func endResolve(failed: Bool = false, now: Date = Date()) {
        lock.lock()
        inFlight = false
        // 成功就把冷却清掉：地址已经对了，下次本来也不会再走到这里
        failedAt = failed ? now : nil
        lock.unlock()
    }

    /// 单测用：把闸复位，别让一个用例的冷却影响下一个
    static func resetForTesting() {
        lock.lock()
        inFlight = false
        failedAt = nil
        waiting = []
        lock.unlock()
    }

    /// 试一趟接入地址，试通就记下来（往后润色、指令、云端识别全跟着对）。
    /// completion 在主线程；true = 主机变了，值得重发一次。
    /// 已经有一趟在飞时**搭它的车**（见 Claim.joined），刚失败过才当场回 false。
    static func resolveNow(apiKey: String, completion: @escaping (Bool) -> Void) {
        switch claim(completion) {
        case .joined:
            Log.info("Qwen host recovery joined the probe already in flight")
            return
        case .refused:
            Log.info("Qwen host recovery skipped: a probe just failed (cooling down)")
            DispatchQueue.main.async { completion(false) }
            return
        case .start:
            break
        }
        Log.warn("Qwen host recovery started: the request failed on a host that was never verified")
        // 开跑那一刻的地址与 Key：落地时拿它们对一次账（下面 stale 那一段）
        let hostBefore = Settings.shared.qwenResolvedHost
        let keyBefore = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        CloudASRSettings.resolveHost(
            apiKey: apiKey,
            candidates: CloudASRSettings.currentHostCandidates(apiKey: apiKey)) { result in
            switch result {
            case .success(let host):
                endResolve()
                // 这几十秒里用户可能已经在设置页粘了另一把 Key（那条路不经过这道闸）。
                // 拿上一把 Key 的答案盖掉他刚验证好的地址，
                // 下一句话就又是 401——与 KeyEntryView 那本账同一条纪律：过期的答案宁可丢掉。
                let keyNow = KeychainHelper.loadAPIKey(account: LLMProvider.qwen.keychainAccount)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stale = Settings.shared.qwenResolvedHost != hostBefore
                    || (keyNow != nil && keyNow != keyBefore)
                guard !stale else {
                    Log.info("Qwen host recovery result dropped: key or endpoint changed while probing")
                    completion(false)
                    notifyWaiting(false)
                    return
                }
                let changed = AlibabaEndpoint.normalizeHost(host)
                    != AlibabaEndpoint.normalizeHost(hostBefore)
                CloudASRSettings.rememberResolution(host: host, model: nil)
                completion(changed)
                notifyWaiting(changed)
            case .failure(let failure):
                endResolve(failed: true)
                // 记的是给用户看的那句文案（只含状态码与服务商错误码），不含 Key
                Log.warn("Qwen host recovery failed: " + String(failure.message.prefix(160)))
                completion(false)
                notifyWaiting(false)
            }
        }
    }
}

// MARK: - 一次性迁移：已经定下来的那台，重新按"最快"选一遍

/// 4.1.4 之前试出来的那台是"顺序试、第一台答应的"，而那个顺序里北京排在新加坡前面。
/// 升上来的人手里因此握着一台"能用但慢得多"的主机——他什么都察觉不到，只觉得云端识别很慢
/// （实测 25.7 秒的录音要 44.7 秒才回来），而 App 永远不会再去试第二台：地址已经定下来了。
///
/// 所以这一版开机重挑一次。三条纪律：
///   • **绝不挡路**——后台跑，听写、录音、启动一概不等它；
///   • 只在"真的问出结果"之后才落标记（离线开机不能把这次迁移白白用掉）；
///   • 与运行中那条恢复探测共用同一道单飞闸，别让同一把 Key 同时飞两趟。
enum AlibabaFastestHostRefresh {

    /// 上一次**问出结果**的那趟整表探测是什么时候（UserDefaults，秒级时间戳；0 = 从来没有）。
    ///
    /// 为什么是时间戳而不是一个"迁移做完了"的布尔：4.1.4 的第一版是一次性迁移，
    /// 那等于假设"最快的那台主机选一次就永远对"。可它会变——用户换地方（这个产品的作者
    /// 半年里横跨两个时区）、服务商调链路、账号新开一个区域端点。选定的那台又是**永不复查**的
    /// （日常听写一句话都不探测），所以一次选错/选旧就再也没人纠正。时间戳让它每周复查一次。
    static let lastProbeKey = "qwenFastestHostProbedAt"

    /// 多久复查一次。一周：这一趟是免费请求，但它会把 Key 发到表里每一台主机上，
    /// 不该天天做；而"换个国家住下来"这种事以周为单位也足够跟上了。
    static let interval: TimeInterval = 7 * 24 * 3600

    /// 这次启动要不要跑（**纯函数**，单测钉死）。
    /// - lastProbe: 上一次问出结果的时间；nil = 从来没有
    /// - hasKey: 钥匙串里有阿里云的 Key（没有 Key 连问都问不出来，跑了也是白跑）
    /// - pastedHost: 存着的接入地址。有就不跑——那是设置文件给的答案，不该被我们按"更快"换掉
    ///   （它死了 / 是串脏值会被 dropsPastedHost 丢掉，那是另一条路）。
    static func shouldRun(lastProbe: Date?, now: Date = Date(),
                          hasKey: Bool, pastedHost: String) -> Bool {
        guard hasKey, AlibabaEndpoint.normalizeHost(pastedHost) == nil else { return false }
        guard let lastProbe = lastProbe else { return true }
        return now.timeIntervalSince(lastProbe) >= interval
    }

    /// 记下"刚刚有一趟整表探测问出了结果"。
    ///
    /// **三条路共用这一个戳**：开机复查、用户在设置/引导里验证 Key、运行中 401 之后的恢复探测。
    /// 后两条跑的是同一趟"挑最快"的整表探测（CloudASRSettings.resolveHost），所以刚验过 Key
    /// 的人不该在下次启动再被探一遍——那是同一个问题问两次，而每问一次都要把 Key 发给每一台主机。
    static func stamp(_ defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: lastProbeKey)
    }

    /// 存着的那个戳（nil = 从来没有）
    static func lastProbe(_ defaults: UserDefaults = .standard) -> Date? {
        let seconds = defaults.double(forKey: lastProbeKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// 开机复查一趟（AppDelegate 在后台队列上调用）。**绝不挡路**：听写、录音、启动都不等它。
    static func runAtLaunch(defaults: UserDefaults = .standard) {
        // 设置文件可能带进来一串拼不出主机名的接入地址。界面上已经没有地方能改它，
        // 留着只会把候选表压成"一台不存在的主机"——开机先把它丢掉（判据是纯函数）
        Settings.shared.dropJunkPastedHost()
        let key = KeychainHelper.loadAPIKey(account: LLMProvider.qwen.keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard shouldRun(lastProbe: lastProbe(defaults),
                        hasKey: !key.isEmpty,
                        pastedHost: Settings.shared.qwenAPIHost) else { return }
        // 单飞闸：开机这一刻用户完全可能已经在说话了，那条路上的恢复探测优先
        guard AlibabaHostRecovery.beginResolve() else {
            Log.info("Qwen host refresh deferred: a probe is already in flight")
            return
        }
        let before = Settings.shared.qwenResolvedHost
        Log.info("Qwen host refresh started")
        AlibabaHostResolver.resolve(
            apiKey: key,
            candidates: CloudASRSettings.currentHostCandidates(apiKey: key)) { result in
            switch result {
            case .success(let host):
                AlibabaHostRecovery.endResolve()
                let changed = AlibabaEndpoint.normalizeHost(host)
                    != AlibabaEndpoint.normalizeHost(before)
                CloudASRSettings.rememberResolution(host: host, model: nil)
                stamp(defaults)
                // 没换和换了是两件事，日志要分得出来：写成 "from=X to=X" 读的人会以为出过什么事
                if changed {
                    Log.info("Qwen host re-resolved (fastest) "
                             + "from=\(before.isEmpty ? "unset" : AlibabaEndpoint.redacted(before)) "
                             + "to=\(AlibabaEndpoint.redacted(host))")
                } else {
                    Log.info("Qwen host refresh kept host=\(AlibabaEndpoint.redacted(host))")
                }
            case .failure(let failure):
                // 离线开机 / 一台都不认：**戳不落**，下次启动再试。存着的那台一个字不动——
                // 它至少还能用，而这一趟什么都没问出来
                AlibabaHostRecovery.endResolve(failed: true)
                Log.warn("Qwen host refresh postponed: " + String(failure.message.prefix(120)))
            }
        }
    }
}

// MARK: - 试出接入地址

/// 候选主机**同时**各问一遍最便宜的那个问题：`GET {host}/compatible-mode/v1/models`，
/// 然后在认这把 Key 的那几台里挑**最快**的。
///
/// 为什么用型号清单而不是直接打识别端点：这一趟**不花钱、不上传任何音频**，
/// 却已经足以判"这把 Key 属不属于这台主机"（401 = 不属于）。识别端点那一趟仍然要发，
/// 但那时主机已经定了，只剩"模型有没有开通"一个变量——两件事分开问，错误信息才说得准。
///
/// 为什么从"顺序试、第一台答应就收工"改成"全试一遍挑最快"（4.1.4，用户 2026-09-20 拍板）：
/// 一把 Key 常常被好几台主机接受（同一个账号在多个区域端点上都在），而 200 只说明"能用"，
/// 不说明"值得用"——实测里北京与新加坡差了一个数量级（见文件顶部）。并发发的是同一个
/// 免费请求，整趟的墙钟时间反而从"最多 7 台 × 每台最多 6 秒"降到"最慢那一台"。
/// 代价：这把 Key 会被送到表里每一台候选主机上（原来最坏情况也是如此，只是现在必然发生）。
enum AlibabaHostResolver {

    /// 一台候选主机的结论（只记状态码、错误码与往返毫秒数，Key 一个字节都不记）
    struct Attempt: Equatable {
        let host: String
        let status: Int
        let code: String?
        /// 这一趟 GET /models 的往返毫秒数。**选哪一台就看它**
        let milliseconds: Int

        init(host: String, status: Int, code: String?, milliseconds: Int = 0) {
            self.host = host
            self.status = status
            self.code = code
            self.milliseconds = milliseconds
        }
    }

    /// 这台主机的回答算不算"就是它"。
    /// 200 自不必说；**403 也算**——鉴权已经过了（Key 属于这台主机），只是这个账号没权限
    /// 或没开通，换一台主机解决不了。
    static func accepts(status: Int) -> Bool {
        (200...299).contains(status) || status == 403
    }

    /// 这个回答算不算"这台不是它，别的还值得看"：401（Key 不属于这台）、404（这台没有这条路）、
    /// 以及 status 0 的网络层错误（专属主机 DNS 解析不了，说明 WorkspaceId 猜错了）。
    /// 并发之后已经不存在"要不要继续试"这个问题了，但这条判据仍然是**报错时挑哪一条**的依据
    /// （见 failureRank）：不属于这一档的失败（限流 / 5xx）跟主机无关，最该原样报出去。
    static func keepsTrying(status: Int) -> Bool {
        status == 401 || status == 404 || status == 0
    }

    /// 两台快得分不出高下的窗口（毫秒）。差在这个数以内就按候选表的顺序选，
    /// 也就是新加坡胜出——一次探测的抖动本来就有几十毫秒，拿它当"更快"是在赌骰子。
    static let tieWindowMilliseconds = 150

    /// 一台都没认下来时，哪一条最值得报给用户（数字越小越先报）。
    /// 顺序就是"这句话能不能帮他找到下一步"：
    ///   ① 不属于 keepsTrying 的失败（限流 / 5xx）——跟主机无关，原样报最有用；
    ///   ② 401——"这把 Key 不属于试过的这些接入地址"，指向 Key 本身；
    ///   ③ 404——地址在、这条路不在；
    ///   ④ status 0——连 DNS 都没通，最没信息量（工作空间编号猜错了就长这样）。
    /// 串行那一版实际就是这个顺序：①当场报，其余报"最后一台"，而候选表末尾是两台
    /// 答得出 401 的共享主机，猜出来的工作空间主机多半停在 0。
    static func failureRank(_ attempt: Attempt) -> Int {
        guard !accepts(status: attempt.status) else { return 9 }
        guard keepsTrying(status: attempt.status) else { return 0 }
        switch attempt.status {
        case 401: return 1
        case 404: return 2
        default: return 3
        }
    }

    /// 试完之后的结论
    enum Decision: Equatable {
        /// 就用这一台（accepted = 一共几台认了这把 Key，写进日志）
        case chosen(Attempt, accepted: Int)
        /// 一台都没认：报这一条（怎么挑见 failureRank）
        case rejected(Attempt)
    }

    /// **纯函数**：候选表 + 每一台的结论 → 用哪一台（或者报哪一条）。单测钉死。
    ///
    /// 选法：认这把 Key 的那几台里最快的；与最快那台差在 tieWindow 以内的算平手，
    /// 平手按候选表的顺序选（所以新加坡排在北京前面这件事只在平手时起作用）。
    static func decide(candidates: [String], attempts: [Attempt],
                       tieWindow: Int = tieWindowMilliseconds) -> Decision {
        func order(_ host: String) -> Int {
            candidates.firstIndex(of: host) ?? candidates.count
        }
        let accepted = attempts.filter { accepts(status: $0.status) }
        if let fastest = accepted.min(by: {
            ($0.milliseconds, order($0.host)) < ($1.milliseconds, order($1.host))
        }) {
            let winner = accepted
                .filter { $0.milliseconds <= fastest.milliseconds + max(0, tieWindow) }
                .min { order($0.host) < order($1.host) } ?? fastest
            return .chosen(winner, accepted: accepted.count)
        }
        let worst = attempts.min {
            (failureRank($0), order($0.host)) < (failureRank($1), order($1.host))
        }
        // 一条结论都没有（全部超时 / 一台都拼不出地址）：报"还没上网"那一档，
        // 与串行那一版的兜底同源
        return .rejected(worst ?? Attempt(host: candidates.first ?? "", status: 0, code: nil))
    }

    /// 并发试一遍，挑最快的那台。completion 在主线程。成功 = 这台主机认这把 Key，而且最快。
    ///
    /// - timeout: 单台的超时。这一趟问的是最便宜的那个问题（GET /models），答得出来的主机
    ///   都是秒回；6 秒还没动静基本就是 DNS 不通或被墙，再等下去只是让状态行一直停在
    ///   「正在验证…」上。
    /// - budget: 整趟的总预算。并发之后它基本只是保险绳（墙钟时间 ≈ 最慢那一台），
    ///   但仍然要有：到点就用**已经回来的**那些结论下判断，报得出原因比无限等下去强。
    static func resolve(apiKey: String,
                        candidates: [String],
                        timeout: TimeInterval = 6,
                        budget: TimeInterval = 30,
                        send: @escaping (URLRequest, @escaping (Int, String?, String?) -> Void) -> Void = defaultSend,
                        completion: @escaping (Result<String, CloudASRFailure>) -> Void) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        func finish(_ result: Result<String, CloudASRFailure>) {
            DispatchQueue.main.async { completion(result) }
        }
        guard !key.isEmpty else {
            finish(.failure(CloudASRFailure(tr("还没有填阿里云 API Key", "No Alibaba API key yet"))))
            return
        }

        var requests: [(host: String, request: URLRequest)] = []
        for host in candidates {
            // 拼不出 URL 的候选（工作空间编号带了非法字符）直接不发：它不是一次失败，
            // 是一条压根不存在的地址，混进结论里只会把报错指向"网络不通"
            guard let url = AlibabaEndpoint.modelsURL(host: host) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            requests.append((host, request))
        }
        guard !requests.isEmpty else {
            finish(.failure(CloudASRFailure(tr("拼不出任何可用的接入地址", "Could not build any endpoint to try"))))
            return
        }

        let started = DispatchTime.now()
        let lock = NSLock()
        var attempts: [Attempt] = []
        var outstanding = requests.count
        var settled = false

        /// 收网。只会下一次结论（预算到点与"最后一台回来了"可能同时发生）。
        func settle(outOfTime: Bool) {
            lock.lock()
            guard !settled else { lock.unlock(); return }
            settled = true
            let collected = attempts
            lock.unlock()
            let elapsed = Log.ms(since: started)
            switch decide(candidates: candidates, attempts: collected) {
            case .chosen(let winner, let accepted):
                Log.info("Qwen host chosen host=\(AlibabaEndpoint.redacted(winner.host)) "
                         + "ms=\(winner.milliseconds) of=\(requests.count) accepted=\(accepted)")
                finish(.success(winner.host))
            case .rejected(let attempt):
                Log.warn("Qwen host resolve \(outOfTime ? "out of time" : "exhausted") "
                         + "tried=\(collected.count) of=\(requests.count) ms=\(elapsed) "
                         + "status=\(attempt.status) code=\(attempt.code ?? "-")")
                finish(.failure(AlibabaASRClient.failure(status: attempt.status,
                                                         code: attempt.code, message: nil)))
            }
        }

        // 预算到点：还没回来的那几台不再等它们
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + budget) {
            settle(outOfTime: true)
        }

        for item in requests {
            let sentAt = DispatchTime.now()
            send(item.request) { status, code, _ in
                let ms = Log.ms(since: sentAt)
                Log.info("Qwen host try host=\(AlibabaEndpoint.redacted(item.host)) "
                         + "status=\(status) code=\(code ?? "-") ms=\(ms)")
                lock.lock()
                attempts.append(Attempt(host: item.host, status: status, code: code, milliseconds: ms))
                outstanding -= 1
                let allBack = outstanding == 0
                lock.unlock()
                if allBack { settle(outOfTime: false) }
            }
        }
    }

    /// 真正上网的那一版（单测传一个假的进来，不碰网络）。
    /// 回调给的是 (HTTP 状态码, 服务端错误码, 服务端原话)；网络层错误一律 status = 0。
    static func defaultSend(_ request: URLRequest,
                            completion: @escaping (Int, String?, String?) -> Void) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(0, nil, nil)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var code: String?
            var message: String?
            if let data = data,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                code = json["code"] as? String
                message = json["message"] as? String
                if code == nil, let err = json["error"] as? [String: Any] {
                    code = (err["code"] as? String) ?? (err["type"] as? String)
                    message = err["message"] as? String
                }
            }
            completion(status, code, message)
        }.resume()
    }
}
