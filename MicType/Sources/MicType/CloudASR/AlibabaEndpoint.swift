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
// 候选地址由 App 按顺序试，试通的那一台存进 qwenResolvedHost，往后正常使用一次都不再探测。
// 用户仍可以把控制台里的「接入地址（apiHost）」粘进来，那就直接用它、不再乱试
// （Key 不该被送到他没指定的主机上）。
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
    static let workspaceSuffixes = [
        "cn-beijing.maas.aliyuncs.com",
        "ap-southeast-1.maas.aliyuncs.com",
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

    /// 候选主机，按"最可能命中"排序。第一项试通就收工。
    ///
    /// - pastedHost: 用户自己粘的接入地址。**粘了就只用它**——他已经把答案给了，
    ///   再拿他的 Key 去试别的主机既多余又不礼貌。
    /// - resolvedHost: 上一次试通的那台（正常使用时候选表就这一项，不再探测）。
    /// - workspace / apiKey: 工作空间专属主机排在共享主机**前面**——知道 WorkspaceId
    ///   就说明这个账号挂在某个区域端点上，先试它命中率最高（北京站用户第一次就通，
    ///   省掉一趟必然 401 的国际站往返；UAE→云端这条链路上一趟就是 1–2 秒）。
    /// - legacyRegionSlug: 老设置里的区域（qwenRegion）。界面上已经没有这一项了，
    ///   但老用户选过的那个值仍是最好的排序线索，所以留着当种子。
    static func candidates(pastedHost: String = "",
                           resolvedHost: String = "",
                           workspace: String = "",
                           legacyRegionSlug: String? = nil,
                           apiKey: String = "") -> [String] {
        if let pinned = normalizeHost(pastedHost) { return [pinned] }

        var out = [String]()
        func add(_ host: String?) {
            guard let h = host, !h.isEmpty, !out.contains(h) else { return }
            out.append(h)
        }
        add(normalizeHost(resolvedHost))

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
        add(sharedInternationalHost)
        add(sharedChinaHost)
        return out
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

// MARK: - 试出接入地址

/// 拿候选主机一台台试，问的是最便宜的那个问题：`GET {host}/compatible-mode/v1/models`。
///
/// 为什么用型号清单而不是直接打识别端点：这一趟**不花钱、不上传任何音频**，
/// 却已经足以判"这把 Key 属不属于这台主机"（401 = 不属于）。识别端点那一趟仍然要发，
/// 但那时主机已经定了，只剩"模型有没有开通"一个变量——两件事分开问，错误信息才说得准。
enum AlibabaHostResolver {

    /// 一台候选主机的结论（只记状态码与错误码，Key 一个字节都不记）
    struct Attempt: Equatable {
        let host: String
        let status: Int
        let code: String?
    }

    /// 这台主机的回答算不算"就是它"。
    /// 200 自不必说；**403 也算**——鉴权已经过了（Key 属于这台主机），只是这个账号没权限
    /// 或没开通，换一台主机解决不了，继续试只会把同一把 Key 无谓地多发几趟。
    static func accepts(status: Int) -> Bool {
        (200...299).contains(status) || status == 403
    }

    /// 还值得再试下一台吗：401（Key 不属于这台）、404（这台没有这条路）、
    /// 以及 status 0 的网络层错误（专属主机 DNS 解析不了，说明 WorkspaceId 猜错了）。
    static func keepsTrying(status: Int) -> Bool {
        status == 401 || status == 404 || status == 0
    }

    /// 逐台试。completion 在主线程。成功 = 这台主机认这把 Key。
    ///
    /// - timeout: 单台的超时。这一趟问的是最便宜的那个问题（GET /models），答得出来的主机
    ///   都是秒回；6 秒还没动静基本就是 DNS 不通或被墙，再等下去只是让状态行一直停在
    ///   「正在验证…」上。
    /// - budget: 整趟的总预算。候选最多 7 台（5 个工作空间后缀 + 2 台共享主机），
    ///   逐台串行又没有总时限的话，UAE→阿里云这种慢链路上能把人晾将近两分钟。
    ///   到点就用目前最好的那次尝试报结论——报得出原因，比无限等下去强。
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
        guard !candidates.isEmpty else {
            finish(.failure(CloudASRFailure(tr("拼不出任何可用的接入地址", "Could not build any endpoint to try"))))
            return
        }

        let started = DispatchTime.now()
        func attempt(_ index: Int, last: Attempt?) {
            let elapsed = Double(Log.ms(since: started)) / 1000
            let outOfTime = elapsed >= budget
            guard index < candidates.count, !outOfTime else {
                let a = last ?? Attempt(host: candidates[0], status: 0, code: nil)
                Log.warn("Qwen host resolve \(outOfTime ? "out of time" : "exhausted") "
                         + "tried=\(index) of=\(candidates.count) seconds=\(Int(elapsed)) "
                         + "lastStatus=\(a.status) lastCode=\(a.code ?? "-")")
                finish(.failure(AlibabaASRClient.failure(status: a.status, code: a.code, message: nil)))
                return
            }
            let host = candidates[index]
            guard let url = AlibabaEndpoint.modelsURL(host: host) else {
                attempt(index + 1, last: last)
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            send(request) { status, code, _ in
                Log.info("Qwen host try host=\(AlibabaEndpoint.redacted(host)) "
                         + "status=\(status) code=\(code ?? "-")")
                let attemptResult = Attempt(host: host, status: status, code: code)
                if accepts(status: status) {
                    finish(.success(host))
                    return
                }
                guard keepsTrying(status: status) else {
                    // 限流 / 5xx 这种"跟主机没关系"的失败：换一台也一样，当面报出来
                    finish(.failure(AlibabaASRClient.failure(status: status, code: code, message: nil)))
                    return
                }
                attempt(index + 1, last: attemptResult)
            }
        }
        attempt(0, last: nil)
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
