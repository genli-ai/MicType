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
// 4.1.4 拿掉过界面上那个「接入地址（可选）」输入框，4.3.1 又**加了回来**（用户 2026-09-21 拍板）：
// 百炼控制台的 API Key 页上明写着一条「接入地址（apiHost）」，而今天实测那一条三样全通
//（对话 / 同步识别 / 实时 WebSocket），自动探测却因为"Key 里 sk-ws- 那一段 ≠ 业务空间 ID"
// 落到了别的主机上。自动挑仍然是默认，但用户要能把控制台上那一条原样填进来并固定用它。
//
// 填了就**只用它**：不探测、不被每周复查换掉、失败也不替他换一台（那样只会让日志和
// 他看到的设置对不上）。拼不出主机名的输入照样不用，但**一个字都不删**——
// 用户 2026-09-21 的原话是"上次填了什么就保持什么"。
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
    /// - pastedHost: 用户填的接入地址（设置里那一栏，或导入的设置文件带来的）。
    ///   **有就只用它**——那是他给的答案，不该拿他的 Key 去试别的主机，失败也不替他换
    ///   （见 CloudASRSettings.resolveHost）。拼不出主机名的输入等同于没填，但不会被删掉。
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

    /// 输入框里这串字**拼不出一个主机名**吗（空着不算——空着是常态）。
    ///
    /// 界面上当场提示用（4.3.1 起「接入地址」输入框又回来了）。这种值在候选表里本来就会被
    /// 静默跳过，所以行为上等同于"没填"（照常自动探测）——但**绝不替用户删掉它**：
    /// 那是他亲手敲进去的东西，删了他连自己填错在哪都看不到（用户 2026-09-21 强调：
    /// 上次填了什么就保持什么）。4.1.4–4.3.0 那条开机/导入时丢脏值的迁移因此撤掉了。
    static func storedHostIsJunk(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && normalizeHost(raw) == nil
    }

    /// 这一次失败是不是**"这台主机不让这把 Key 访问端点"**（纯函数，单测钉死）。
    ///
    /// 2026-09-20 第一把真 Key 的实测（UAE）：新建的新加坡工作空间 Key 在
    /// `{ws}.ap-southeast-1…` 上，`GET /compatible-mode/v1/models` 回 200，而
    /// chat 与识别两个端点都回 **403**：
    ///   • OpenAI 兼容模式：`{"error":{"type":"access_denied","code":"access_denied",`
    ///     `"message":"Workspace endpoint access denied."}}`
    ///   • DashScope 原生：`{"code":"Endpoint.AccessDenied","message":"Workspace endpoint access denied."}`
    /// 同一把 Key 在 dashscope-intl 上一切正常。
    ///
    /// 为什么必须单独认出来：这是**换一台主机就能解决**的 403，而 403 的通用话术
    /// （"去模型广场开通这个模型"）在这一档下是纯粹的误导；而且它出现在一台
    /// "已经验证过"的主机上——那个验证是 GET /models 挣来的，我们现在知道它什么都不证明。
    /// 所以这一条要绕过 hostSettled 那道闸，直接触发重新试一圈（见 AlibabaHostRecovery.action）。
    static func deniesEndpointAccess(status: Int, code: String?, message: String?) -> Bool {
        guard status == 403 else { return false }
        let hay = ((code ?? "") + " " + (message ?? "")).lowercased()
        return hay.contains("access_denied")
            || hay.contains("endpoint.accessdenied")
            || hay.contains("endpoint access denied")
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

    /// 对话端点：**确认**这台主机肯不肯真的干活用它（见 AlibabaHostResolver 的第二轮）。
    /// 与润色/指令真正发请求的是同一条路径，所以"确认通过"就是"润色能用"。
    static func chatCompletionsURL(host: String) -> URL? {
        guard let h = normalizeHost(host) else { return nil }
        return URL(string: "https://" + h + compatiblePath + "/chat/completions")
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
    /// - hostSettled: 接入地址已经定下来了——上一次真的试通过。
    ///   定下来的主机吃 401 是另一回事（Key 过期 / 被删），再试一圈也只会得到同样的 401。
    /// - canWaitForResolve: 这一趟等得起那 30 秒吗（润色等不起，见上面）
    /// - status: HTTP 状态码；0 = 还没上网
    /// - code / message: 服务商给的错误码与原话（认"端点访问被拒"那一档要用，见下面）
    /// - urlErrorCode: 网络层错误码（NSURLError*），没有就传 nil
    static func action(isAlibaba: Bool,
                       hostSettled: Bool,
                       hostPinned: Bool = false,
                       canWaitForResolve: Bool,
                       status: Int,
                       code: String? = nil,
                       message: String? = nil,
                       urlErrorCode: Int?,
                       attemptsLeft: Int) -> Action {
        guard isAlibaba, attemptsLeft > 0 else { return .none }
        // 用户自己填了接入地址：**一趟都不探测**（4.3.1，用户 2026-09-21 拍板）。
        // 他给的是答案，不是建议——失败就如实报失败，让他去改那一栏或清空它；
        // 背着他换一台的结果是"我明明填了 A，日志里却在发 B"，那比失败更难查。
        // 这道闸要排在 access-denied 那一条前面：那一条的全部意义就是"自动换一台"。
        guard !hostPinned else { return .none }
        // **端点访问被拒（403 access_denied）要绕过 hostSettled 那道闸**（4.1.5）。
        // 那个"已经定下来了"是 GET /models 挣来的，而 2026-09-20 的实测证明它什么都不证明：
        // 同一台主机 /models 回 200、chat 与识别回 403。不绕过的话，用户会被永久钉死在
        // 一台什么都干不了的主机上，而 App 手上明明有一套能换一台的机制。
        // 连发的代价由既有的单飞闸 + 60 秒冷却兜住（见 claim / failureCooldown）：
        // 真的每台都被拒时，最多一分钟试一圈，不会每句话都试。
        if AlibabaEndpoint.deniesEndpointAccess(status: status, code: code, message: message) {
            return canWaitForResolve ? .resolveAndRetry : .resolveInBackground
        }
        guard !hostSettled else { return .none }
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

    /// 上一次那趟探测是**哪一版逻辑**跑出来的（UserDefaults）。
    ///
    /// 为什么光有时间戳不够（4.1.5）：4.1.4 的探测只问了 GET /models，而那一问什么都不证明
    /// ——它可能选中一台 chat 与识别全 403 的主机。升上来的人手里已经有一个"刚刚问过"的戳，
    /// 于是最长要等七天才会被重挑一次，而这七天里他每句话都失败。版本号对不上就立刻重跑一次。
    static let logicVersionKey = "qwenFastestHostProbeVersion"

    /// 当前这一版探测逻辑：1 = 只问 /models（4.1.4）；2 = 加上"确认它肯不肯干活"（4.1.5）。
    /// **改探测逻辑就 +1**，老戳自然作废。
    static let logicVersion = 2

    /// 多久复查一次。一周：这一趟是免费请求，但它会把 Key 发到表里每一台主机上，
    /// 不该天天做；而"换个国家住下来"这种事以周为单位也足够跟上了。
    static let interval: TimeInterval = 7 * 24 * 3600

    /// 这次启动要不要跑（**纯函数**，单测钉死）。
    /// - lastProbe: 上一次问出结果的时间；nil = 从来没有
    /// - stampedVersion: 那一趟是哪一版逻辑跑的（0 = 没有戳 / 4.1.4 之前）
    /// - hasKey: 钥匙串里有阿里云的 Key（没有 Key 连问都问不出来，跑了也是白跑）
    /// - pastedHost: 用户填的接入地址。有就不跑——他给的是答案，不该被我们按"更快"换掉。
    ///   拼不出主机名的输入等同于没填（照常复查），但那串字一个都不会被删。
    static func shouldRun(lastProbe: Date?, stampedVersion: Int = logicVersion,
                          now: Date = Date(),
                          hasKey: Bool, pastedHost: String) -> Bool {
        guard hasKey, AlibabaEndpoint.normalizeHost(pastedHost) == nil else { return false }
        guard let lastProbe = lastProbe else { return true }
        // 老逻辑留下的戳不算数：那一趟可能选中了一台什么都干不了的主机
        guard stampedVersion >= logicVersion else { return true }
        return now.timeIntervalSince(lastProbe) >= interval
    }

    /// 记下"刚刚有一趟整表探测问出了结果"。
    ///
    /// **三条路共用这一个戳**：开机复查、用户在设置/引导里验证 Key、运行中 401 之后的恢复探测。
    /// 后两条跑的是同一趟"挑最快"的整表探测（CloudASRSettings.resolveHost），所以刚验过 Key
    /// 的人不该在下次启动再被探一遍——那是同一个问题问两次，而每问一次都要把 Key 发给每一台主机。
    static func stamp(_ defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: lastProbeKey)
        // 时间和版本永远一起写：只写时间会让下一版的"老戳作废"判据失灵
        defaults.set(logicVersion, forKey: logicVersionKey)
    }

    /// 存着的那个戳（nil = 从来没有）
    static func lastProbe(_ defaults: UserDefaults = .standard) -> Date? {
        let seconds = defaults.double(forKey: lastProbeKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// 存着的那个戳是哪一版逻辑留下的（0 = 没有戳，或者 4.1.4 那一版只写了时间）
    static func stampedVersion(_ defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: logicVersionKey)
    }

    /// 开机复查一趟（AppDelegate 在后台队列上调用）。**绝不挡路**：听写、录音、启动都不等它。
    static func runAtLaunch(defaults: UserDefaults = .standard) {
        // 拼不出主机名的接入地址（用户填错、或设置文件带进来的）**不删**：它在候选表里
        // 本来就等同于没填，所以下面那趟复查照跑，而屏幕上那一栏留着原样让他自己改
        let key = KeychainHelper.loadAPIKey(account: LLMProvider.qwen.keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard shouldRun(lastProbe: lastProbe(defaults),
                        stampedVersion: stampedVersion(defaults),
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

    /// 免费那一轮（GET /models）之后的结论
    enum Decision: Equatable {
        /// 认这把 Key 的那几台，**按"该先用谁"排好序**（第一项最快，平手按候选表顺序）。
        /// 4.1.5 起不再是"选出一台"就完事：200 只证明这台主机认这把 Key，
        /// 不证明它肯干活（见下面 confirm 那一段），所以要把整张排好的名单交出去逐台确认。
        case ranked([Attempt])
        /// 一台都没认：报这一条（怎么挑见 failureRank）
        case rejected(Attempt)
    }

    /// **纯函数**：候选表 + 每一台的结论 → 认这把 Key 的那几台（排好序），或者该报哪一条。单测钉死。
    ///
    /// 排法：最快的在前；与前一名差在 tieWindow 以内的算平手，平手按候选表的顺序
    ///（所以新加坡排在北京前面这件事只在平手时起作用）。整张名单都要，而不只是第一名——
    /// 第一名可能压根不肯干活（见 confirm 那一段），那时要能顺着名单往下走。
    static func decide(candidates: [String], attempts: [Attempt],
                       tieWindow: Int = tieWindowMilliseconds) -> Decision {
        func order(_ host: String) -> Int {
            candidates.firstIndex(of: host) ?? candidates.count
        }
        var pool = attempts.filter { accepts(status: $0.status) }
        if !pool.isEmpty {
            // 逐名选出：每一轮都先看"剩下的里谁最快"，再在与它平手的那几台里按候选表顺序挑。
            // 直接按 (ms, order) 排序是不对的——那样 300ms 的新加坡会排在 280ms 的北京后面，
            // 而这两台在网络抖动面前本来就是一回事（tieWindow 的全部意义）。候选最多 7 台，O(n²) 无所谓。
            var ranked: [Attempt] = []
            while !pool.isEmpty {
                guard let fastest = pool.min(by: {
                    ($0.milliseconds, order($0.host)) < ($1.milliseconds, order($1.host))
                }) else { break }
                let winner = pool
                    .filter { $0.milliseconds <= fastest.milliseconds + max(0, tieWindow) }
                    .min { order($0.host) < order($1.host) } ?? fastest
                ranked.append(winner)
                pool.removeAll { $0.host == winner.host }
            }
            return .ranked(ranked)
        }
        let worst = attempts.min {
            (failureRank($0), order($0.host)) < (failureRank($1), order($1.host))
        }
        // 一条结论都没有（全部超时 / 一台都拼不出地址）：报"还没上网"那一档，
        // 与串行那一版的兜底同源
        return .rejected(worst ?? Attempt(host: candidates.first ?? "", status: 0, code: nil))
    }

    // MARK: - 第二轮：这台主机肯不肯真的干活

    /// 为什么 GET /models 通过还不够（2026-09-20，第一把真 Key 的实测，UAE）：
    /// 新建的新加坡工作空间 Key 在 `{ws}.ap-southeast-1…` 上
    ///   • `GET /compatible-mode/v1/models` → **200**（480 ms）
    ///   • `POST /compatible-mode/v1/chat/completions` → **403 access_denied**
    ///     "Workspace endpoint access denied."
    ///   • `POST /api/v1/…/generation`（识别）→ **403 Endpoint.AccessDenied**
    /// 而同一把 Key 在 `dashscope-intl` 上三样全是 200。两台的 /models 只差 100–180 ms，
    /// 正好落在平手窗口里，于是"排在前面"的工作空间主机赢了——赢下来的那台一件事也干不了。
    /// 4.1.3 及以前的串行版有同一个洞（工作空间主机排在共享主机前面）。
    ///
    /// 所以第一名选出来之后要**再问一句真话**：发一次最小的 chat 请求（max_tokens=1，
    /// 不开思考），只看它肯不肯受理。代价是几个 token，买的是"选定的主机真的能用"。
    enum ConfirmOutcome: Equatable {
        /// 200：这台真的干活了
        case confirmed
        /// 401 / 403 / 连不上：这台干不了这件事，看下一台
        case unusable
        /// 其余状态（400、404 模型不存在、429、5xx）：请求**被受理了**，只是这一次没成。
        /// 端点访问权是有的，所以它是个合格的备胎——但还是先找有没有能给 200 的。
        case reachable
    }

    /// 一次确认的结果（同样只记状态码、错误码与毫秒数）
    struct Confirmation: Equatable {
        let host: String
        let status: Int
        let code: String?
        let milliseconds: Int

        init(host: String, status: Int, code: String? = nil, milliseconds: Int = 0) {
            self.host = host
            self.status = status
            self.code = code
            self.milliseconds = milliseconds
        }
    }

    /// 状态码 → 这一台算不算数（纯函数）
    static func classify(status: Int) -> ConfirmOutcome {
        if (200...299).contains(status) { return .confirmed }
        if status == 401 || status == 403 || status == 0 { return .unusable }
        return .reachable
    }

    /// 确认阶段的下一步
    enum ConfirmStep: Equatable {
        /// 接着问这一台
        case confirm(String)
        /// 定了。fallback = 没有任何一台给出 200，用的是"受理了但这次没成"的那台备胎
        case settle(host: String, fallback: Bool)
        /// 排好序的那几台没一个能用：报这一条（nil = 压根没得可问）
        case giveUp(Confirmation?)
    }

    /// **纯函数**：排好序的候选 + 已经拿到的确认结果 → 下一步做什么。单测钉死。
    ///
    /// 规矩（用户 2026-09-20 定）：
    ///   • 拿到 200 就收工，后面的一台都不问（每问一台都要花几个 token）；
    ///   • 401 / 403 / 连不上 = 这台不行，问下一台；
    ///   • 其余状态说明端点访问是通的（模型名不对、限流、服务端出错都属于这一档）——
    ///     记成备胎，但继续找 200；全程没有 200 时用排名最靠前的那个备胎；
    ///   • 一个都不剩：报排名最靠前那一台的失败原因（它最可能是"本该用的那一台"）。
    static func nextConfirmStep(ranked: [Attempt],
                                confirmations: [Confirmation]) -> ConfirmStep {
        if let ok = confirmations.first(where: { classify(status: $0.status) == .confirmed }) {
            return .settle(host: ok.host, fallback: false)
        }
        let done = Set(confirmations.map(\.host))
        if let next = ranked.first(where: { !done.contains($0.host) }) {
            return .confirm(next.host)
        }
        // 问完了：按排名（不是按回来的先后）挑备胎，再挑要报的那一条
        for attempt in ranked {
            guard let result = confirmations.first(where: { $0.host == attempt.host }),
                  classify(status: result.status) == .reachable else { continue }
            return .settle(host: result.host, fallback: true)
        }
        for attempt in ranked {
            if let result = confirmations.first(where: { $0.host == attempt.host }) {
                return .giveUp(result)
            }
        }
        return .giveUp(confirmations.first)
    }

    /// 确认那一轮的失败要报哪一句。
    ///
    /// **全都是"端点访问被拒"时换一句专门的话**：这一档里 Key 本身是好的（401 的话
    /// 连 /models 都过不了），问题出在这把 Key 属于一个没开放端点访问的工作空间——
    /// 让他去核对 Key、去模型广场开通模型，全是白跑。
    /// **不指定"去默认业务空间新建"**：2026-09-20 实测一把刚建的 Key 在工作空间主机上 403、
    /// 同一个账号的老 Key 却通——我们并不知道阿里云按什么放行，只说我们知道的：
    /// Key 是好的、访问被拒、该去看这把 Key 所属业务空间的权限。
    static func confirmFailure(_ confirmations: [Confirmation],
                               reported: Confirmation?) -> CloudASRFailure {
        let denied = !confirmations.isEmpty && confirmations.allSatisfy {
            AlibabaEndpoint.deniesEndpointAccess(status: $0.status, code: $0.code, message: nil)
        }
        if denied {
            return CloudASRFailure(workspaceAccessDeniedCopy, code: reported?.code, status: 403)
        }
        let fallback = reported ?? Confirmation(host: "", status: 0)
        return AlibabaASRClient.failure(status: fallback.status, code: fallback.code, message: nil)
    }

    /// 用户**自己填了接入地址**、而那一台没通时说的话（纯函数，单测钉死）。
    ///
    /// 为什么不能沿用通用那句：通用那句是「试过的每一个接入地址都不认这把 Key」——
    /// 而这一趟只试了一台，还是他指定的那一台。照那句去核对 Key 是查错了方向：
    /// 十有八九是这一栏里的地址与这把 Key 不是一对（今天实测：业务空间 ID ≠ Key 里
    /// `sk-ws-` 后面那一段，按 Key 猜出来的主机 /models 过、真请求 403）。
    /// 所以这句话只说两件事：**是这一台不收**，以及**下一步在哪**——改这一栏，或清空它交回自动探测。
    ///
    /// 返回 nil = 沿用原来那句（端点访问被拒那一档自己的话更准，它点名了"去默认业务空间建 Key"）。
    static func pastedHostFailureCopy(status: Int, code: String?) -> String? {
        guard !AlibabaEndpoint.deniesEndpointAccess(status: status, code: code, message: nil) else {
            return nil
        }
        let tail = status > 0 ? " (\(status))" : ""
        return tr("你填的接入地址没能用这把 Key 接通\(tail)。到百炼控制台核对「接入地址」，或清空这一栏交回自动探测。",
                  "The API host you entered did not accept this key\(tail). Check the host in the Model Studio console, or clear the field to hand the job back to auto-detection.")
    }

    /// 那一句专门的话（全 App 唯一出处：确认阶段与运行中的 403 都引用它）
    static var workspaceAccessDeniedCopy: String {
        tr("这把 Key 有效，但阿里云拒绝了接口访问 (403)。请到百炼控制台检查这把 Key 所属业务空间的权限，或新建一把 Key。",
           "This key is valid, but Alibaba Cloud denied endpoint access (403). Check the permissions of the key's workspace in the Model Studio console, or create a new key.")
    }

    /// 确认那一趟的请求体（纯函数，单测钉住每一个字段）。
    ///
    /// 最小的一次真请求：`max_tokens: 1` + 不开思考，问的只是"你肯不肯受理"。
    /// 模型名用**用户自己那一档**（他可能填了一个只有他开通了的型号）——
    /// 拿一个他没开通的型号去问，会得到 400/404，那属于 reachable（端点是通的），
    /// 判断仍然正确，只是没那么准。
    static func confirmBody(model: String) -> [String: Any] {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "model": name.isEmpty ? LLMCatalog.qwenDefaultModel : name,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
            // 3.5 线起默认开思考，一次"确认"用不着它，还会把往返拖长（见 LLMClient）
            "enable_thinking": false,
        ]
    }

    /// 确认要用的型号：用户这一档存着什么就用什么，空着才退到出厂默认
    static func currentConfirmModel() -> String {
        let stored = Settings.shared.qwenModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? LLMCatalog.qwenDefaultModel : stored
    }

    /// 并发试一遍挑出排名，再**逐台确认它肯不肯干活**，返回真正能用的那一台。completion 在主线程。
    ///
    /// 两轮的分工：
    ///   ① `GET /compatible-mode/v1/models` 全表并发——免费、不传音频，问"这把 Key 属不属于这台"；
    ///   ② 按排名逐台 `POST /compatible-mode/v1/chat/completions`（max_tokens=1）——
    ///      花几个 token，问"这台肯不肯真的受理"。第一轮 200、第二轮 403 的主机真实存在
    ///      （见 ConfirmOutcome 那段实测），只做第一轮等于把用户钉死在一台什么都干不了的主机上。
    ///
    /// - timeout: 单台的超时（两轮同一个数）。这两趟问的都是最便宜的问题，答得出来的主机
    ///   都是秒回；6 秒还没动静基本就是 DNS 不通或被墙，再等下去只是让状态行一直停在
    ///   「正在验证…」上。
    /// - budget: **第一轮**的总预算。并发之后它基本只是保险绳（墙钟时间 ≈ 最慢那一台），
    ///   但仍然要有：到点就用**已经回来的**那些结论下判断，报得出原因比无限等下去强。
    /// - confirmModel: 确认那一趟用哪个型号（默认读用户这一档的设置）
    static func resolve(apiKey: String,
                        candidates: [String],
                        timeout: TimeInterval = 6,
                        budget: TimeInterval = 30,
                        confirmModel: String? = nil,
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
        // 第二轮要用的型号。在这里取而不是在 confirmStage 里取：那是一次 UserDefaults 读，
        // 而 confirmStage 会被递归调用（每确认一台一次）
        let model = confirmModel ?? currentConfirmModel()

        /// 收网。只会下一次结论（预算到点与"最后一台回来了"可能同时发生）。
        func settle(outOfTime: Bool) {
            lock.lock()
            guard !settled else { lock.unlock(); return }
            settled = true
            let collected = attempts
            lock.unlock()
            let elapsed = Log.ms(since: started)
            switch decide(candidates: candidates, attempts: collected) {
            case .ranked(let ranked):
                confirmStage(ranked: ranked, accepted: ranked.count)
            case .rejected(let attempt):
                Log.warn("Qwen host resolve \(outOfTime ? "out of time" : "exhausted") "
                         + "tried=\(collected.count) of=\(requests.count) ms=\(elapsed) "
                         + "status=\(attempt.status) code=\(attempt.code ?? "-")")
                finish(.failure(AlibabaASRClient.failure(status: attempt.status,
                                                         code: attempt.code, message: nil)))
            }
        }

        /// 第二轮：按排名逐台问一句真话。**串行**——每问一台都要花几个 token，
        /// 而绝大多数时候第一台就成了（并发问等于每次都把所有主机的钱都花掉）。
        func confirmStage(ranked: [Attempt], accepted: Int, confirmations: [Confirmation] = []) {
            func chose(_ host: String, fallback: Bool) {
                let ms = confirmations.first { $0.host == host }?.milliseconds ?? 0
                Log.info("Qwen host chosen host=\(AlibabaEndpoint.redacted(host)) "
                         + "ms=\(ms) of=\(requests.count) accepted=\(accepted) "
                         + "confirmed=\(fallback ? "fallback" : "true")")
                finish(.success(host))
            }
            switch nextConfirmStep(ranked: ranked, confirmations: confirmations) {
            case .settle(let host, let fallback):
                chose(host, fallback: fallback)
            case .giveUp(let reported):
                Log.warn("Qwen host confirm exhausted tried=\(confirmations.count) "
                         + "of=\(ranked.count) status=\(reported?.status ?? 0) "
                         + "code=\(reported?.code ?? "-")")
                finish(.failure(confirmFailure(confirmations, reported: reported)))
            case .confirm(let host):
                guard let url = AlibabaEndpoint.chatCompletionsURL(host: host),
                      let body = try? JSONSerialization.data(withJSONObject: confirmBody(model: model)) else {
                    // 拼不出这一台的地址：当成"不能用"，接着问下一台
                    confirmStage(ranked: ranked, accepted: accepted,
                                 confirmations: confirmations + [Confirmation(host: host, status: 0)])
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = timeout
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                let sentAt = DispatchTime.now()
                send(request) { status, code, _ in
                    let ms = Log.ms(since: sentAt)
                    Log.info("Qwen host confirm host=\(AlibabaEndpoint.redacted(host)) "
                             + "status=\(status) code=\(code ?? "-") ms=\(ms)")
                    confirmStage(ranked: ranked, accepted: accepted,
                                 confirmations: confirmations
                                    + [Confirmation(host: host, status: status,
                                                    code: code, milliseconds: ms)])
                }
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
