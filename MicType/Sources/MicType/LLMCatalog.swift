import Foundation

// MARK: - 大模型型号目录（v4.0）

/// 「哪些服务商、哪些型号、默认用谁、接口地址怎么拼、谁不吃 temperature、坏了怎么跟用户说」
/// 全都收在这一个文件里。
/// 为什么单独成文件：这些是**随服务商换代而变**的知识，型号或端点一更新只该改这里；
/// 网络层（LLMClient）、设置界面、迁移逻辑都只读这里，不各自硬写型号名与 URL。
/// 目录本身只是快选与默认值——模型名输入框永远可以手填任意型号（自建网关、新发布的模型）。
enum LLMCatalog {

    // MARK: - 预设与默认

    /// OpenAI 快选（2026-09 在售主力）。luna 成本敏感、terra 平衡、sol 旗舰、astra 最强。
    static let openaiPresets = ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-6-astra"]
    /// DeepSeek 快选。老的 deepseek-v4-flash / deepseek-chat / deepseek-reasoner 已全部下线（见迁移）。
    static let deepseekPresets = ["deepseek-flash", "deepseek-v4-pro"]
    /// Qwen（DashScope 兼容模式）快选。3.8 是当前代；`qwen-flash` / `qwen-plus` / `qwen-max`
    /// 是阿里维护的稳定别名——换代时它们自己指向新模型，怕过时的用户直接用别名最省心。
    static let qwenPresets = ["qwen3.8-flash", "qwen3.8-max", "qwen3.7-plus",
                             "qwen-flash", "qwen-plus", "qwen-max"]

    /// 润色高频、只是改写 → 用最便宜的一档；指令低频、要质量 → 往上一档。
    /// （旗舰放在每句话都要跑的润色路径上是纯烧钱：luna 与 sol 的输入价差 20 倍。）
    static let openaiPolishDefault = "gpt-5.6-luna"
    static let openaiCommandDefault = "gpt-5.6-terra"
    static let deepseekPolishDefault = "deepseek-flash"
    static let deepseekCommandDefault = "deepseek-v4-pro"
    static let qwenPolishDefault = "qwen3.8-flash"
    static let qwenCommandDefault = "qwen3.8-max"

    static func presets(for provider: LLMProvider) -> [String] {
        switch provider {
        case .openai: return openaiPresets
        case .deepseek: return deepseekPresets
        case .qwen: return qwenPresets
        // 自定义端点与本机模型的型号名只有用户自己知道（Ollama 里是 `llama3.1:8b` 这种本地 tag）：
        // 写死一份猜出来的清单只会误导人，让「刷新模型列表」去问端点本身。
        case .custom, .local: return []
        }
    }

    static func polishDefault(for provider: LLMProvider) -> String {
        switch provider {
        case .openai: return openaiPolishDefault
        case .deepseek: return deepseekPolishDefault
        case .qwen: return qwenPolishDefault
        case .custom, .local: return ""
        }
    }

    static func commandDefault(for provider: LLMProvider) -> String {
        switch provider {
        case .openai: return openaiCommandDefault
        case .deepseek: return deepseekCommandDefault
        case .qwen: return qwenCommandDefault
        case .custom, .local: return ""
        }
    }

    // MARK: - 质量二选一（快 / 最好）

    /// 用户对「花多少钱换多好的结果」只做**一次**选择，选完写死两个型号字段。
    /// 铁律：这不是运行时自动切换——MicType 永远不会替用户在两档之间跳。
    enum QualityTier: String, CaseIterable {
        case fast
        case best

        var displayName: String {
            switch self {
            case .fast: return tr("快", "Fast")
            case .best: return tr("最好", "Best")
            }
        }
    }

    /// 一档质量对应的两个型号（润色 + 指令）
    struct ModelPair: Equatable {
        let polish: String
        let command: String
    }

    /// **整个产品里唯一一张「档位 → 型号」表**：型号换代只改这里（以及上面的默认值常量），
    /// 界面层一个型号名都不认识。nil = 这一档没有内置型号可推荐（自定义端点 / 本机模型的
    /// 型号名只有用户自己知道），界面据此把质量选择器整个藏掉，而不是摆一个点了没反应的控件。
    static func models(provider: LLMProvider, tier: QualityTier) -> ModelPair? {
        switch (provider, tier) {
        // 「快」这一档 == 各服务商的出厂默认：干净安装打开设置页看到的就是「快」，不是空白
        case (.openai, .fast): return ModelPair(polish: openaiPolishDefault, command: openaiCommandDefault)
        case (.openai, .best): return ModelPair(polish: "gpt-5.6-terra", command: "gpt-5.6-sol")
        case (.deepseek, .fast): return ModelPair(polish: deepseekPolishDefault, command: deepseekCommandDefault)
        // DeepSeek 只有两个型号：最好档把润色也抬到 pro（润色路径会关掉它的思考模式，不至于慢到没法用）
        case (.deepseek, .best): return ModelPair(polish: "deepseek-v4-pro", command: "deepseek-v4-pro")
        case (.qwen, .fast): return ModelPair(polish: qwenPolishDefault, command: qwenCommandDefault)
        case (.qwen, .best): return ModelPair(polish: "qwen3.8-max", command: "qwen3.8-max")
        case (.custom, _), (.local, _): return nil
        }
    }

    /// 当前这两个型号落在哪一档（纯函数）。nil = 两档都不是——**用户自己在高级区挑过型号**，
    /// 界面必须如实显示「自选」，绝不能把选择器硬钉在某一档上骗他（那等于偷偷改回我们的型号）。
    static func tier(provider: LLMProvider, polish: String, command: String) -> QualityTier? {
        let p = polish.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return QualityTier.allCases.first { tier in
            guard let pair = models(provider: provider, tier: tier) else { return false }
            return pair.polish == p && pair.command == c
        }
    }

    /// 质量选择器下面那句「它到底换了什么」。写出真实型号名：藏起来只会让人不敢点。
    /// nil = 这个服务商没有内置两档（选择器本身也不显示）。
    static func qualitySummary(provider: LLMProvider) -> String? {
        guard let fast = models(provider: provider, tier: .fast),
              let best = models(provider: provider, tier: .best) else { return nil }
        return tr("「快」= 润色 \(fast.polish) + 指令 \(fast.command)；「最好」= 润色 \(best.polish) + 指令 \(best.command)。选一下就同时改掉这两个型号，想自己挑就去「高级」。",
                  "Fast = \(fast.polish) for polish and \(fast.command) for commands. Best = \(best.polish) and \(best.command). Picking a tier writes both model fields - pick your own under Advanced.")
    }

    /// 某个服务商的「润色型号 / 指令型号」分别存在哪两个 UserDefaults 键上。
    /// 为什么值得一个纯函数：选一下质量档就要**同时**改这两个字段，而设置页与引导页各写一份
    /// switch 的话，早晚有一处在加服务商时漏掉一档——漏掉的表现是「点了质量没反应」。
    static func modelKeys(for provider: LLMProvider) -> (polish: String, command: String) {
        switch provider {
        case .openai: return (SettingsKeys.chatModel, SettingsKeys.openaiCommandModel)
        case .deepseek: return (SettingsKeys.deepseekModel, SettingsKeys.deepseekCommandModel)
        case .qwen: return (SettingsKeys.qwenModel, SettingsKeys.qwenCommandModel)
        case .custom: return (SettingsKeys.customModel, SettingsKeys.customCommandModel)
        case .local: return (SettingsKeys.localModel, SettingsKeys.localCommandModel)
        }
    }

    /// 选中某一档质量要写回的键值（纯函数）。
    /// 空字典 = 这个服务商没有内置两档（自定义端点 / 本机模型），一个字节都不该写。
    static func qualityWrites(provider: LLMProvider, tier: QualityTier) -> [String: String] {
        guard let pair = models(provider: provider, tier: tier) else { return [:] }
        let keys = modelKeys(for: provider)
        return [keys.polish: pair.polish, keys.command: pair.command]
    }

    // MARK: - 配置齐了没有

    /// AI（润色 + 语音指令）现在到底跑不跑得起来：引导最后一屏的两种收尾话术、
    /// 以及「没配 AI」的可见状态都据此二选一。三样都得有：
    ///   • 凭据——本机模型那一档的"空 Key"由 LLMClient.credential 判成**有**凭据，这里只收结论；
    ///   • 拼得出来的接口地址——Qwen 区域端点缺 WorkspaceId 时是空串；
    ///   • 非空的润色型号——自定义端点与本机模型没有内置型号，用户没填就是没配好。
    /// 纯函数、不读全局状态：调用方把三样喂进来，单测才钉得住。
    static func aiReady(hasCredential: Bool, baseURL: String, polishModel: String) -> Bool {
        guard hasCredential else { return false }
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !polishModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 去哪儿申请 Key / 固定的 Key 与费用说法

    /// 「去申请 Key ↗」指向的页面。nil = 我们没有一条可以打包票的地址
    /// （Qwen 的控制台随区域不同；自定义端点与本机模型压根不是一家服务商）——
    /// 与 billingURL 同一条纪律：**宁可不给按钮，也不塞一个猜出来的链接**。
    static func apiKeyConsoleURL(for provider: LLMProvider) -> String? {
        switch provider {
        case .openai: return "https://platform.openai.com/api-keys"
        case .deepseek: return "https://platform.deepseek.com"
        case .qwen, .custom, .local: return nil
        }
    }

    /// Key 怎么存 / 钱怎么付。**设置页与引导页必须逐字用这两句**（同一个事实只写一处）。
    static var keyStorageNote: String {
        tr("Key 加密存在 macOS 钥匙串里，仅本机可读，从不写进明文文件，也不随设置导出。",
           "Your key is encrypted in the macOS Keychain, readable only on this Mac, never written to a plain file and never included in a settings export.")
    }
    static var billingNote: String {
        tr("费用由服务商直接结给你，MicType 不经手、不加价，也不代发你的请求。",
           "You pay the provider directly. MicType takes no cut and never proxies your requests.")
    }
    /// 新账号的第一道坎（BoltAI 把它写在同一屏是对的：拿到 Key 也可能是 429/余额不足）
    static var newAccountNote: String {
        tr("新账号通常要先在服务商那边绑卡或充一点额度，Key 才真的能用。",
           "A brand-new account usually has to add a card or buy some credit before the key works.")
    }

    // MARK: - 接口地址

    /// DashScope 兼容模式的接入区域。**必须做成选择器**：URL 里带 WorkspaceId，
    /// 手抄错一个字符的表现是「鉴权失败」，用户会一直去翻 Key 而不是看地址。
    enum QwenRegion: String, CaseIterable {
        case international   // 国际站总入口
        case us              // 国际站美国入口
        case beijing         // 区域端点（下面四个都要 WorkspaceId）
        case singapore
        case tokyo
        case hongkong

        var displayName: String {
            switch self {
            case .international: return tr("国际站（dashscope-intl）", "International (dashscope-intl)")
            case .us: return tr("国际站 · 美国（dashscope-us）", "International - US (dashscope-us)")
            case .beijing: return tr("中国 · 北京（需 WorkspaceId）", "China - Beijing (needs a workspace ID)")
            case .singapore: return tr("新加坡 ap-southeast-1（需 WorkspaceId）",
                                       "Singapore ap-southeast-1 (needs a workspace ID)")
            case .tokyo: return tr("东京 ap-northeast-1（需 WorkspaceId）",
                                   "Tokyo ap-northeast-1 (needs a workspace ID)")
            case .hongkong: return tr("香港 cn-hongkong（需 WorkspaceId）",
                                      "Hong Kong cn-hongkong (needs a workspace ID)")
            }
        }

        /// 区域端点的主机名里第一段是 WorkspaceId，没有它压根拼不出地址
        var regionSlug: String? {
            switch self {
            case .international, .us: return nil
            case .beijing: return "cn-beijing"
            case .singapore: return "ap-southeast-1"
            case .tokyo: return "ap-northeast-1"
            case .hongkong: return "cn-hongkong"
            }
        }

        var requiresWorkspaceID: Bool { regionSlug != nil }
    }

    /// Qwen 的 Base URL 由「区域 + WorkspaceId」推出来，用户永远不用手拼。
    /// 返回 ""（而不是偷偷退回国际站）表示这套配置还不完整——**绝不能因为 WorkspaceId 没填，
    /// 就把 Key 和听写文本默默发到另一个区域去**。调用方据此报「地址还没填完」。
    static func qwenBaseURL(region: QwenRegion, workspaceID: String) -> String {
        guard let slug = region.regionSlug else {
            switch region {
            case .us: return "https://dashscope-us.aliyuncs.com/compatible-mode/v1"
            default: return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
            }
        }
        let ws = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ws.isEmpty else { return "" }
        return "https://\(ws).\(slug).maas.aliyuncs.com/compatible-mode/v1"
    }

    /// 本机模型运行时。端口写死是刻意的：这两个软件的默认端口就是它们的招牌，
    /// 改过端口的人属于「自定义端点」那一档。
    enum LocalRuntime: String, CaseIterable {
        case ollama
        case lmstudio

        var displayName: String {
            switch self {
            case .ollama: return "Ollama (11434)"
            case .lmstudio: return "LM Studio (1234)"
            }
        }

        var baseURL: String {
            switch self {
            case .ollama: return "http://localhost:11434/v1"
            case .lmstudio: return "http://localhost:1234/v1"
            }
        }
    }

    /// 自定义 Base URL 的毛病。分四档是因为「怎么改」完全不同：
    /// 少了版本段（`/v1`）的地址拼出来是 404，用户会以为模型名写错了。
    enum BaseURLProblem: Equatable {
        case empty
        case malformed
        case insecure
        case noVersionSegment

        var message: String {
            switch self {
            case .empty:
                return tr("还没填接口地址", "No base URL yet")
            case .malformed:
                return tr("这不像一个接口地址，要形如 https://api.example.com/v1",
                          "That does not look like a base URL - it should look like https://api.example.com/v1")
            case .insecure:
                return tr("只接受 https（本机地址 localhost 除外）",
                          "Only https is accepted (localhost is the one exception)")
            case .noVersionSegment:
                return tr("地址要带版本段，例如结尾的 /v1；少了它每次调用都是 404",
                          "The URL needs its version segment, such as a trailing /v1 - without it every call is a 404")
            }
        }
    }

    /// 本机地址（Ollama / LM Studio）——明文 http 只在这里放行，也只有这里可以不填 API Key。
    static func isLocalHost(_ text: String) -> Bool {
        guard let host = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?
                .host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }

    /// 自定义端点的校验（纯函数）。nil = 可用。
    static func validateCustomBaseURL(_ text: String) -> BaseURLProblem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased() else { return .malformed }
        guard scheme == "https" || scheme == "http" else { return .malformed }
        if scheme == "http", !isLocalHost(trimmed) { return .insecure }
        // 版本段：`/v1`、`/v1beta`、`/api/paas/v4` 都算。少了它就是 404 —— 而报错写的是「找不到模型」。
        let segments = url.path.split(separator: "/").map(String.init)
        let hasVersion = segments.contains { segment in
            guard segment.lowercased().hasPrefix("v"), segment.count >= 2 else { return false }
            return segment.dropFirst().first?.isNumber == true
        }
        return hasVersion ? nil : .noVersionSegment
    }

    // MARK: - 模型列表（GET {base}/models）

    /// 不能拿来聊天的型号 id 片段：嵌入、图像、语音、审核。
    /// 为什么要过滤：OpenAI 的 /models 有上百条，DashScope 更多，全塞进下拉框等于没有下拉框。
    private static let nonChatModelMarkers = ["embedding", "vision", "audio", "tts",
                                              "whisper", "dall-e", "moderation"]

    /// `GET {base}/models` 的 `data[].id` → 能用的聊天型号（去重 + 排序，纯函数）
    static func usableModelIDs(from ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let lower = id.lowercased()
            guard !nonChatModelMarkers.contains(where: { lower.contains($0) }) else { continue }
            guard seen.insert(id).inserted else { continue }
            out.append(id)
        }
        return out.sorted()
    }

    /// 下拉框里最终显示的清单：**手写预设永远在前**（它们是我们选过的、知道贵不贵的那几个），
    /// 端点新报上来的排在后面。拉取失败时这个函数压根不会被调用——下拉框保持预设原样。
    static func mergedModelList(presets: [String], fetched: [String]) -> [String] {
        var out = presets
        var seen = Set(presets)
        for id in usableModelIDs(from: fetched) where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }

    // MARK: - 联网搜索（一个开关，各服务商写法不同）

    /// 各服务商的联网搜索写法。对外只有一个开关，形状差异全在这里收敛。
    enum WebSearchStyle: Equatable {
        /// OpenAI Responses 的 `tools:[{type:"web_search"}]`——唯一会回传来源链接的一档
        case openaiResponsesTool
        /// DashScope 兼容模式：body 里 `enable_search` + `search_options`，**不回传来源**
        case qwenEnableSearch
        /// OpenRouter：`plugins:[{id:"web"}]`
        case openrouterPlugin
        /// 这个端点没有内建搜索 → 开关置灰，绝不假装能用
        case unsupported
    }

    static func searchStyle(provider: LLMProvider, baseURL: String) -> WebSearchStyle {
        let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?.lowercased() ?? ""
        if host == "openrouter.ai" || host.hasSuffix(".openrouter.ai") { return .openrouterPlugin }
        switch provider {
        case .openai:
            // web_search 是 Responses 独有；OpenAI 档指向第三方网关时只有 chat/completions，没有它
            return LLMClient.usesResponsesAPI(baseURL: baseURL) ? .openaiResponsesTool : .unsupported
        case .qwen:
            return .qwenEnableSearch
        case .deepseek, .custom, .local:
            return .unsupported
        }
    }

    /// 联网搜索的单价——**全 App 唯一出处**。设置页开关旁与隐私说明（PrivacyCopy.webSearchBilled）
    /// 都引用它，不许各写各的：两处价钱对不上的时候，用户没法知道哪句算数。
    static var webSearchPriceNote: String { tr("每次搜索约 $0.01（OpenAI 按 $10 / 1000 次计）外加 token 费用，默认关闭。",
                                       "About $0.01 per search (OpenAI bills $10 per 1000 calls) plus tokens. Off by default.") }

    /// Fast 档同样要把代价写在开关旁：token 单价翻倍
    static var fastTierPriceNote: String { tr("延迟更低更稳，token 单价约 2 倍，默认关闭。实际档位由服务商决定，可能被降回 default。",
                                      "Lower and steadier latency at about 2x the token price, off by default. The provider decides the actual tier and may fall back to default.") }

    /// 悬浮窗/历史里那句「已联网 · 3 来源」。0 条来源也要说「已联网」——
    /// Qwen 那档压根不回传来源，用户仍该知道这次调用花了搜索的钱。
    static func webSearchNote(citationCount: Int) -> String {
        guard citationCount > 0 else { return tr("已联网", "Searched the web") }
        return tr("已联网 · \(citationCount) 来源", "Searched the web · \(citationCount) sources")
    }

    /// `user_location`（approximate）。只用本机时区与地区码——**不报城市**：
    /// 时区里的城市名（Asia/Dubai）不等于用户所在的城市，拿它当位置既不准又多送了一份信息。
    static func approximateUserLocation(timeZone: TimeZone = .current,
                                        locale: Locale = .current) -> [String: String] {
        var location = ["type": "approximate", "timezone": timeZone.identifier]
        if let region = locale.region?.identifier, region.count == 2 {
            location["country"] = region.uppercased()
        }
        return location
    }

    // MARK: - 型号能力

    /// 推理系模型只接受默认 temperature，发了自定义值直接 400（gpt-5.5 / gpt-5.6-* / gpt-6-* / *-pro / o 系）。
    /// 命中就**根本不发** temperature，省掉「400 → 去参重试」那趟废请求（UAE 链路每趟往返都贵）；
    /// LLMClient 里的去参重试只作兜底。
    /// 注：`-pro` 也会命中 deepseek-v4-pro——DeepSeek 的思考档同样忽略 temperature，不发是对的。
    static func rejectsCustomTemperature(_ model: String) -> Bool {
        let m = model.lowercased()
        if m.contains("5.5") || m.contains("5.6") || m.contains("gpt-6") { return true }
        if m.contains("-pro") { return true }
        // o 系（o1 / o3 / o4 / 以后的 o5…）：字母 o 紧跟一位数字
        if let first = m.first, first == "o", let second = m.dropFirst().first, second.isNumber {
            return true
        }
        return false
    }

    /// `reasoning.effort: "none"`（最快、几乎不产生推理 token）是否可用。
    /// gpt-6 线明确不支持 none（官方模型表），发了会 400 → 退到 "low"。
    static func supportsEffortNone(_ model: String) -> Bool {
        !model.lowercased().contains("gpt-6")
    }

    /// 这次调用该发什么 effort：润色永远要最快的一档；指令要一点推理但不要多。
    static func effort(purpose: LLMClient.Purpose, model: String) -> String {
        switch purpose {
        case .polish: return supportsEffortNone(model) ? "none" : "low"
        case .command: return "low"
        }
    }

    /// max_output_tokens：按输入长度给足余量。
    /// 为什么不写死 2048：润色的输出长度≈原文长度，10 分钟口述会被静默截断成半句话
    /// （Responses 的推理 token 也算在这个额度里，所以底线要留一截）。
    static func maxOutputTokens(inputCharacters: Int, minimum: Int) -> Int {
        let estimated = 1024 + max(0, inputCharacters) * 2
        return min(max(estimated, minimum), 32768)
    }

    /// 润色/指令各自的底线额度（短输入时用得上）
    static let polishMinOutputTokens = 2048
    static let commandMinOutputTokens = 4096

    // MARK: - 一次性迁移到 5.6 线

    /// v4.0 迁移标记。写在 UserDefaults 里，只跑一次。
    static let migrationFlagKey = "migratedTo56"

    /// 仍停在「历史自动默认」上的润色型号。这些值不是用户挑的，是各版 MicType 自己写进去的：
    /// nil（没存过）/ gpt-4o-mini（更早的默认）/ gpt-5.4-nano（3.2.1 拆分时写的）/ gpt-5.5（migratedPolishTo55 写的）。
    private static let autoPolishModels: Set<String?> = [nil, "gpt-4o-mini", "gpt-5.4-nano", "gpt-5.5"]
    /// 同理，指令型号的历史自动默认只有 gpt-5.4-mini（和没存过）。
    private static let autoCommandModels: Set<String?> = [nil, "gpt-5.4-mini"]
    /// DeepSeek 这几个型号**已经不存在了**（调用直接 404/400），所以无论是不是用户手选的都得改名。
    private static let deadDeepSeekModels: [String: String] = [
        "deepseek-v4-flash": deepseekPolishDefault,
        "deepseek-chat": deepseekPolishDefault,
        "deepseek-reasoner": deepseekCommandDefault,
    ]

    /// 迁移规则（**纯函数**，便于单测钉死「手选过的一个都不动」这条铁律）。
    /// 入参：当前存着什么（key = SettingsKeys，值为 nil 表示没存过 / 用的是注册默认值）。
    /// 返回：需要写回的键值；空字典 = 什么都不用改。
    static func migrationTo56(current: [String: String?]) -> [String: String] {
        var writes: [String: String] = [:]

        func value(_ key: String) -> String? {
            guard let stored = current[key], let raw = stored else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        // OpenAI：只搬还停在自动默认上的用户。手选过 gpt-5.4 / gpt-5.4-mini 当润色的人
        // 是自己做的决定，替他改掉就是「替用户做主」——铁律不许。
        if autoPolishModels.contains(value(SettingsKeys.chatModel)) {
            writes[SettingsKeys.chatModel] = openaiPolishDefault
        }
        if autoCommandModels.contains(value(SettingsKeys.openaiCommandModel)) {
            writes[SettingsKeys.openaiCommandModel] = openaiCommandDefault
        }

        // DeepSeek：没存过 → 新默认；存着已下线的型号 → 按等价关系改名（不改就是每次调用都失败）。
        for (key, fallback) in [(SettingsKeys.deepseekModel, deepseekPolishDefault),
                                (SettingsKeys.deepseekCommandModel, deepseekCommandDefault)] {
            guard let current = value(key) else {
                writes[key] = fallback
                continue
            }
            if let renamed = deadDeepSeekModels[current.lowercased()] {
                writes[key] = renamed
            }
        }

        return writes
    }

    // MARK: - 错误话术

    /// 一条可以直接摆给用户看的失败说明 + 可选的「下一步」链接。
    /// 纪律：每条都要说清**该做什么**（换服务商 / 等几秒 / 去充值），不能只报一个数字。
    struct ErrorCopy: Equatable {
        let text: String
        /// 有下一步可点时给链接（目前只有余额不足），没有则 nil
        let actionLabel: String?
        let actionURL: String?

        /// 悬浮窗那类只能显示纯文本的地方用这个：把下一步拼在句尾
        var fullText: String {
            guard let label = actionLabel, let url = actionURL else { return text }
            return text + tr("（", " (") + label + tr("：", ": ") + url + tr("）", ")")
        }
    }

    /// HTTP 失败 → 双语话术（纯函数，单测钉死 6 个分支）。
    /// - status：HTTP 状态码
    /// - provider：决定「去充值」指向哪个控制台，以及 403 时建议换去哪
    /// - code：响应里的 `error.code` / `error.type`（429 靠它区分限流与余额不足）
    /// - message：响应里的 `error.message`，截断后附在句尾（服务商常在这里写明真正原因）
    static func describeHTTPError(status: Int, provider: LLMProvider,
                                  code: String?, message: String?) -> ErrorCopy {
        let detail: String = {
            guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty else { return "" }
            return tr("：", ": ") + String(message.prefix(60))
        }()
        let hay = ((code ?? "") + " " + (message ?? "")).lowercased()

        switch status {
        case 401:
            return ErrorCopy(text: tr("API Key 无效或已失效 (401)，请检查是否粘贴完整、有没有被撤销",
                                      "Invalid or revoked API key (401) — check that it was pasted in full") + detail,
                             actionLabel: nil, actionURL: nil)
        case 403:
            return ErrorCopy(text: forbiddenText(for: provider) + detail,
                             actionLabel: nil, actionURL: nil)
        case 404:
            return ErrorCopy(text: tr("找不到这个模型 (404)，请检查模型名和 Base URL",
                                      "Model not found (404) — check the model id and the base URL") + detail,
                             actionLabel: nil, actionURL: nil)
        case 429:
            // 「等一会儿」和「去充钱」是两件完全不同的事，并成一句话用户根本不知道该干什么。
            if hay.contains("insufficient_quota") || hay.contains("quota") || hay.contains("billing")
                || hay.contains("balance") {
                return ErrorCopy(text: tr("账户余额不足 (429)，充值后即可继续",
                                          "Out of credit (429) — add credit to continue") + detail,
                                 actionLabel: billingURL(for: provider) == nil ? nil : tr("去充值", "Add credit"),
                                 actionURL: billingURL(for: provider))
            }
            return ErrorCopy(text: tr("请求太密，被服务商限流了 (429)，等几秒再说一次",
                                      "Rate limited by the provider (429) — wait a few seconds and try again") + detail,
                             actionLabel: nil, actionURL: nil)
        case 503:
            return ErrorCopy(text: tr("服务商暂时没有容量 (503)，稍后再试",
                                      "The provider has no capacity right now (503) — try again shortly") + detail,
                             actionLabel: nil, actionURL: nil)
        default:
            return ErrorCopy(text: tr("接口返回 ", "API returned ") + "\(status)" + detail,
                             actionLabel: nil, actionURL: nil)
        }
    }

    /// 403 说的根本不是同一件事，所以**必须按服务商分流**：
    ///   • OpenAI —— 国家/地区封锁（用户在 UAE，这条命中率不低）；
    ///   • Qwen（DashScope）—— 几乎总是"模型没在百炼控制台开通 / 账户欠费 / 子工作空间没权限"，
    ///     跟地区无关。说成地区封锁会把用户推去做一件没用的事（措辞与云端识别那条路一致）；
    ///   • DeepSeek / 自定义端点 —— Key 的权限或网关的策略；
    ///   • 本机模型 —— Ollama / LM Studio 拒绝了来源，跟"国家/地区"更是一点关系都没有。
    /// 另外：建议换去的那一档永远不能是他当前正在用的那一档（以前写死"改用 DeepSeek"，
    /// DeepSeek 用户收到的就是一句"改用 DeepSeek"）。
    private static func forbiddenText(for provider: LLMProvider) -> String {
        switch provider {
        case .openai:
            return tr("你所在的国家/地区不支持这个服务 (403)。可以改用 DeepSeek 或 Qwen，或在设置里填一个自定义端点",
                      "This service is not supported in your country or region (403). Switch to DeepSeek or Qwen, or point MicType at a custom endpoint in Settings")
        case .qwen:
            return tr("这个模型还没在阿里云百炼开通，或账户欠费、子工作空间无权 (403)。请到百炼控制台 → 模型广场把它开通一次",
                      "This model is not enabled for your account, or the account is in arrears, or the sub-workspace lacks access (403). Enable it once in the Alibaba Model Studio console (Model Gallery)")
        case .deepseek:
            return tr("服务商拒绝了这次请求 (403)：这把 Key 可能没有该模型的权限，或你所在的地区不被支持。可以改用 OpenAI，或在设置里填一个自定义端点",
                      "The provider refused this request (403): this key may lack access to the model, or your region is not supported. Switch to OpenAI, or point MicType at a custom endpoint in Settings")
        case .custom:
            return tr("这个端点拒绝了请求 (403)：Key 可能没有该模型的权限，或网关按地区/来源做了限制。请到该端点自己的控制台核对",
                      "This endpoint refused the request (403): the key may lack access to the model, or the gateway restricts your region or origin. Check it in that endpoint's own console")
        case .local:
            return tr("本机模型服务拒绝了这次请求 (403)。Ollama / LM Studio 默认只接受本机来源，请确认它正在运行、并允许来自 MicType 的请求",
                      "The local model server refused this request (403). Ollama and LM Studio only accept local origins by default - make sure it is running and allows requests from MicType")
        }
    }

    /// 超时话术（已经重试过一趟才会走到这里）
    static func timeoutCopy() -> ErrorCopy {
        ErrorCopy(text: tr("请求超时（已重试一次，网络到 API 太慢）",
                           "Request timed out (retried once — the network to the API is too slow)"),
                  actionLabel: nil, actionURL: nil)
    }

    /// 「去充值」指向哪个控制台。nil = 我们没有一条可以打包票的充值地址
    /// （Qwen 的控制台随区域不同，自定义端点与本机模型压根没有账单）——**宁可不给按钮，
    /// 也不塞一个猜出来的链接**：点进去是 404 比没有按钮更让人心慌。
    private static func billingURL(for provider: LLMProvider) -> String? {
        switch provider {
        case .openai: return "https://platform.openai.com/settings/organization/billing"
        case .deepseek: return "https://platform.deepseek.com/top_up"
        case .qwen, .custom, .local: return nil
        }
    }
}
