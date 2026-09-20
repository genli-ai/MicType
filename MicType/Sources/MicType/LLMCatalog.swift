import Foundation

// MARK: - 大模型型号目录（v4.0）

/// 「哪些服务商、哪些型号、默认用谁、接口地址怎么拼、谁不吃 temperature、坏了怎么跟用户说」
/// 全都收在这一个文件里。
/// 为什么单独成文件：这些是**随服务商换代而变**的知识，型号或端点一更新只该改这里；
/// 网络层（LLMClient）、设置界面、迁移逻辑都只读这里，不各自硬写型号名与 URL。
/// 目录本身只是快选与默认值——模型名输入框永远可以手填任意型号（自建网关、新发布的模型）。
enum LLMCatalog {

    // MARK: - 预设与默认

    /// 各档服务商的**默认型号**。4.0.1 起只有一个默认值：润色和指令用同一个，
    /// 而且一律是这家最主流的那个好模型（用户 2026-09-19 拍板：默认绝不能是便宜的那一档）。
    ///
    /// 4.0.0 是「润色用最便宜的、指令用贵一档」——省下来的钱是真的，但代价是**默认体验**
    /// 由最弱的那个模型代表，而绝大多数人从不改默认值。想省钱的人在「模型」下拉里选得到。
    static let openaiDefaultModel = "gpt-5.6-sol"
    static let deepseekDefaultModel = "deepseek-v4-pro"
    static let qwenDefaultModel = "qwen3.8-max"

    /// OpenAI 快选（2026-09 在售主力）。顺序= 下拉里的顺序：强的在前。
    static let openaiPresets = ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
    /// DeepSeek 快选。老的 deepseek-v4-flash / deepseek-chat / deepseek-reasoner 已全部下线（见迁移）。
    static let deepseekPresets = ["deepseek-v4-pro", "deepseek-flash"]
    /// Qwen（DashScope 兼容模式）快选。3.8 是当前代；`qwen-flash` / `qwen-plus` / `qwen-max`
    /// 是阿里维护的稳定别名——换代时它们自己指向新模型，怕过时的用户直接用别名最省心。
    static let qwenPresets = ["qwen3.8-max", "qwen3.7-plus", "qwen3.8-flash",
                             "qwen-max", "qwen-plus", "qwen-flash"]

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

    /// 这一档服务商的默认型号（润色与指令同一个）。"" = 这一档没有内置型号。
    static func defaultModel(for provider: LLMProvider) -> String {
        switch provider {
        case .openai: return openaiDefaultModel
        case .deepseek: return deepseekDefaultModel
        case .qwen: return qwenDefaultModel
        case .custom, .local: return ""
        }
    }

    /// 润色 / 指令的默认值现在是同一个。两个函数都留着，是因为调用方问的是**不同的键**
    /// （chatModel vs openaiCommandModel），读起来比到处写 defaultModel 清楚。
    static func polishDefault(for provider: LLMProvider) -> String { defaultModel(for: provider) }
    static func commandDefault(for provider: LLMProvider) -> String { defaultModel(for: provider) }

    // MARK: - 型号选单（界面上唯一的型号决定）

    /// 「模型」下拉里的一项：型号名 + 一句大白话标签。
    /// 标签可以是空串——同一档里并列的第二、第三个型号不必每个都贴一个词。
    struct ModelChoice: Equatable {
        let id: String
        let note: String
    }

    /// **整个产品里唯一一张「服务商 → 可选型号」表**：型号换代只改这里（以及上面的默认值），
    /// 界面层一个型号名都不认识。空数组 = 这一档没有内置型号（自定义端点 / 本机模型的型号名
    /// 只有用户自己知道），界面据此把下拉整个藏掉，而不是摆一个点了没反应的控件。
    ///
    /// 4.0.0 这里是「快 / 最好」两档。用户 2026-09-19 拍板换成型号本身：
    /// 「快」「最好」这种词既没说清花多少钱，也不让想指定型号的人指定。
    static func modelMenu(for provider: LLMProvider) -> [ModelChoice] {
        switch provider {
        case .openai:
            return [ModelChoice(id: "gpt-6-astra", note: tr("最强", "Strongest")),
                    ModelChoice(id: openaiDefaultModel, note: tr("旗舰（默认）", "Flagship (default)")),
                    ModelChoice(id: "gpt-5.6-terra", note: tr("均衡", "Balanced")),
                    ModelChoice(id: "gpt-5.6-luna", note: tr("省钱", "Cheapest"))]
        case .deepseek:
            return [ModelChoice(id: deepseekDefaultModel, note: tr("默认", "Default")),
                    ModelChoice(id: "deepseek-flash", note: tr("快", "Fast"))]
        case .qwen:
            return [ModelChoice(id: qwenDefaultModel, note: tr("默认", "Default")),
                    ModelChoice(id: "qwen3.7-plus", note: ""),
                    ModelChoice(id: "qwen3.8-flash", note: tr("省钱", "Cheapest"))]
        case .custom, .local:
            return []
        }
    }

    /// 下拉里显示的那一行（型号名永远在前：它才是要发出去的东西）
    static func modelLabel(_ choice: ModelChoice) -> String {
        choice.note.isEmpty ? choice.id : choice.id + " · " + choice.note
    }

    /// 选中一个型号要写回的键值（**润色与指令一起改**，纯函数）。
    /// 空字典 = 型号名是空的，一个字节都不写。
    static func modelWrites(provider: LLMProvider, model: String) -> [String: String] {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let keys = modelKeys(for: provider)
        return [keys.polish: trimmed, keys.command: trimmed]
    }

    /// 当前这两个字段落在选单的哪一项上。nil = 两个字段不一样（在「高级」里分开设过），
    /// 或者是一个选单里没有的型号——界面据此显示「自定义…」，绝不把用户钉回我们的某一项。
    static func selectedMenuModel(provider: LLMProvider, polish: String, command: String) -> String? {
        let p = polish.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, p == c else { return nil }
        return modelMenu(for: provider).contains { $0.id == p } ? p : nil
    }

    /// 把两个型号字段拉成同一个值（**纯函数**，4.1.1 的一次性迁移与设置导入都走它）。
    ///
    /// 4.1.1 起「润色模型」和「指令模型」不再是两个决定（用户 2026-09-20 拍板：
    /// 全部同一个）。界面上分开设的入口已经没有了，可老设置里、别人给的设置文件里，
    /// 仍然可能存着两个不一样的值——那会变成一条**看不见的设置**：下拉显示「自定义…」，
    /// 按住说指令跑的却是另一个型号。返回要写回的键值，空字典 = 本来就是一样的。
    static func unifyModelWrites(current: [String: String?]) -> [String: String] {
        var writes: [String: String] = [:]
        for provider in LLMProvider.allCases {
            let keys = modelKeys(for: provider)
            guard let polish = storedValue(current, keys.polish) else { continue }
            let command = storedValue(current, keys.command)
            guard command != polish else { continue }
            writes[keys.command] = polish
        }
        return writes
    }

    /// 某个服务商的「润色型号 / 指令型号」分别存在哪两个 UserDefaults 键上。
    /// 为什么值得一个纯函数：在「模型」下拉里选一下就要**同时**改这两个字段，而设置页与引导页
    /// 各写一份 switch 的话，早晚有一处在加服务商时漏掉一档——漏掉的表现是「选了没反应」。
    static func modelKeys(for provider: LLMProvider) -> (polish: String, command: String) {
        switch provider {
        case .openai: return (SettingsKeys.chatModel, SettingsKeys.openaiCommandModel)
        case .deepseek: return (SettingsKeys.deepseekModel, SettingsKeys.deepseekCommandModel)
        case .qwen: return (SettingsKeys.qwenModel, SettingsKeys.qwenCommandModel)
        case .custom: return (SettingsKeys.customModel, SettingsKeys.customCommandModel)
        case .local: return (SettingsKeys.localModel, SettingsKeys.localCommandModel)
        }
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

    /// 引导收尾那一行到底该说哪一种话。**三档，不是两档**：
    /// 「配好了但润色关着」（选了「只用本地」却留着一把 Key）既不是 ready 也不是没配——
    /// 此刻轻点听写一个字都不润色，而按住说指令照常会调用云端并计费。
    /// 只用 aiReady 判的话，这一档会被说成「AI 润色和语音指令都就绪了」，用户白等一个
    /// 不会发生的润色。
    enum AIStatus: Equatable {
        /// 凭据、地址、型号齐了，润色也开着
        case ready
        /// 配齐了，但润色档位是关的：只有按住说指令还走 AI
        case commandsOnly
        /// 还没配 AI（或者这一档缺型号名 / 拼不出地址）
        case off
    }

    static func aiStatus(hasCredential: Bool, baseURL: String,
                         polishModel: String, polishEnabled: Bool) -> AIStatus {
        guard aiReady(hasCredential: hasCredential, baseURL: baseURL, polishModel: polishModel) else {
            return .off
        }
        return polishEnabled ? .ready : .commandsOnly
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
    ///
    /// **只认回环地址**。以前这里还放行任意 `*.local`，那是错的：`.local` 是 mDNS 名字，
    /// 解析走的是局域网里没有鉴权的广播，指向的是**别人的机器**。把它当成"本机"有两个后果——
    /// 校验不再提示明文风险，`credential()` 还会免掉 API Key 要求；于是
    /// `http://studio.local:11434/v1` 这种地址会把听写文本、以及钥匙串里已存的那把 Key
    /// （`credential()` 优先返回它）以明文 Bearer 发到办公室 Wi-Fi 上，谁应答 mDNS 谁收。
    static func isLocalHost(_ text: String) -> Bool {
        guard let host = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?
                .host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// 这个地址是不是"明文 http 发往非回环主机"。
    ///
    /// 为什么要有这个判断、而且要放在**发请求的地方**：`validateCustomBaseURL` 只是设置页上
    /// 一行橙字，既不拦保存也不拦请求（dispatch 从不调用它），而 ATS 的 `NSAllowsLocalNetworking`
    /// 放行的是整个局域网（回环、`.local`、link-local、RFC1918），拦不住这件事。
    /// 真正会泄漏 Key 与听写文本的是那一趟请求本身，所以闸门必须在 LLMClient 那一侧。
    /// 纯函数，单测钉住。
    static func isCleartextToRemoteHost(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "http" else { return false }
        return !isLocalHost(trimmed)
    }

    /// 明文地址被拦下来时对用户说的那一句（不替他改地址——改成 https 可能压根连不上，
    /// 那是"替用户做主"；说清楚为什么被拦、该怎么改就够了）。
    static var cleartextBlockedCopy: String {
        tr("这个接口地址是明文 http，而且指向的不是本机（localhost）——API Key 和听写文本会在网络上裸奔。请改成 https，或把服务跑在本机。",
           "This endpoint is plain http and does not point at this Mac (localhost), so your API key and dictated text would travel unencrypted. Use https, or run the service locally.")
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
    ///
    /// 4.1.1 起默认**开着**（用户 2026-09-20 拍板：支持联网搜索的服务商一律默认开，
    /// 不支持的那几档连开关都不摆）。这句话跟着改：写着"默认关闭"而实际开着，
    /// 比不说更糟——用户按这句话判断自己有没有在花这笔钱。
    static var webSearchPriceNote: String { tr("每次搜索约 $0.01（OpenAI 按 $10 / 1000 次计）外加 token 费用，默认开启。",
                                       "About $0.01 per search (OpenAI bills $10 per 1000 calls) plus tokens. On by default.") }

    /// 阿里云那一档的联网搜索价钱。**我们报不出一个准数**：DashScope 的搜索按它自己的
    /// 价目结算，随套餐和地区变——编一个数字比不给数字糟得多，所以只说"按服务商计费"。
    static var providerBilledSearchNote: String { tr("联网搜索按服务商自己的价目计费，默认开启。",
                                            "Web search is billed at your provider's own rates. On by default.") }

    /// 这一档的开关旁边该摆哪句价钱。nil = 这个端点压根没有联网搜索（开关也不摆）。
    /// 纯函数：价钱与"有没有这个功能"必须同源，否则会出现"这家没有搜索"+"每次 $0.01"并排。
    static func webSearchPriceNote(style: WebSearchStyle) -> String? {
        switch style {
        case .openaiResponsesTool: return webSearchPriceNote
        case .qwenEnableSearch, .openrouterPlugin: return providerBilledSearchNote
        case .unsupported: return nil
        }
    }

    /// 优先处理档同样要把代价写在开关旁：token 单价翻倍。
    /// **单价只写这一处**——4.1.0 之前开关标题里还硬写着一个「2 倍」，改价就会有两个数字打架。
    /// 「实际档位由服务商决定」是解释不是代价，收进「高级」那颗 ⓘ（advancedInfo）。
    static var fastTierPriceNote: String { tr("延迟更低更稳，token 单价约 2 倍，默认关闭。",
                                      "Lower, steadier latency at about 2x the token price. Off by default.") }

    /// 服务商回传的 service_tier 原值算不算"真的跑在优先档上"。
    /// OpenAI 回 "fast"，别的兼容端点习惯叫 "priority"——后者也得算数，
    /// 否则真跑在优先档上的那一次会被染成橙色的"被降级了"。纯函数。
    static func servedPriorityTier(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "fast" || value == "priority"
    }

    /// service_tier 原值 → 界面说法。认不出的档位**原样显示**：硬翻成"普通档"是在编，
    /// 原值摆出来用户至少能拿去问服务商。纯函数。
    static func serviceTierName(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fast", "priority": return tr("优先档", "the priority tier")
        case "default": return tr("普通档", "the standard tier")
        case "flex": return tr("弹性档（更慢、更便宜）", "the flex tier (slower and cheaper)")
        default: return raw
        }
    }

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
    /// 目标型号名在这里写死、不跟着默认值走：这一步是「把死型号换成最接近的活型号」，
    /// 不是「换成我们推荐的那个」——默认值以后再变，也不该悄悄改掉这条等价关系。
    private static let deadDeepSeekModels: [String: String] = [
        "deepseek-v4-flash": "deepseek-flash",
        "deepseek-chat": "deepseek-flash",
        "deepseek-reasoner": "deepseek-v4-pro",
    ]

    /// 读一条「当前存着什么」。nil / 空白 = 没存过（用的是注册默认值）。
    private static func storedValue(_ current: [String: String?], _ key: String) -> String? {
        guard let stored = current[key], let raw = stored else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 迁移规则（**纯函数**，便于单测钉死「手选过的一个都不动」这条铁律）。
    /// 入参：当前存着什么（key = SettingsKeys，值为 nil 表示没存过 / 用的是注册默认值）。
    /// 返回：需要写回的键值；空字典 = 什么都不用改。
    static func migrationTo56(current: [String: String?]) -> [String: String] {
        var writes: [String: String] = [:]

        func value(_ key: String) -> String? { storedValue(current, key) }

        // OpenAI：只搬还停在自动默认上的用户。手选过 gpt-5.4 / gpt-5.4-mini 当润色的人
        // 是自己做的决定，替他改掉就是「替用户做主」——铁律不许。
        if autoPolishModels.contains(value(SettingsKeys.chatModel)) {
            writes[SettingsKeys.chatModel] = defaultModel(for: .openai)
        }
        if autoCommandModels.contains(value(SettingsKeys.openaiCommandModel)) {
            writes[SettingsKeys.openaiCommandModel] = defaultModel(for: .openai)
        }

        // DeepSeek：没存过 → 新默认；存着已下线的型号 → 按等价关系改名（不改就是每次调用都失败）。
        for key in [SettingsKeys.deepseekModel, SettingsKeys.deepseekCommandModel] {
            guard let current = value(key) else {
                writes[key] = defaultModel(for: .deepseek)
                continue
            }
            if let renamed = deadDeepSeekModels[current.lowercased()] {
                writes[key] = renamed
            }
        }

        return writes
    }

    // MARK: - 一次性迁移到「默认用最好的型号」（4.0.1）

    /// 4.0.1 迁移标记。写在 UserDefaults 里，只跑一次。
    static let bestDefaultMigrationFlagKey = "migratedToBestDefault"

    /// 4.0.0 由 **MicType 自己**写进去的那几对组合（润色便宜一档、指令贵一档）。
    /// 这几对不是用户挑的，是出厂默认或上一次迁移的产物——所以可以整体抬到新默认；
    /// 只要有一边对不上，就说明用户动过手，一个字都不碰。
    private static let autoPairs40: [LLMProvider: (polish: String, command: String)] = [
        .openai: ("gpt-5.6-luna", "gpt-5.6-terra"),
        .deepseek: ("deepseek-flash", "deepseek-v4-pro"),
        .qwen: ("qwen3.8-flash", "qwen3.8-max"),
    ]

    /// 一处被迁移改掉的型号：改的是哪个键、从什么改成什么。
    /// 有了 from 才说得出那句"我把你的型号换了"——只报新值等于让用户自己去猜原来是什么。
    struct ModelChange: Equatable {
        let key: String
        let from: String
        let to: String
    }

    /// 迁移规则的**真身**（纯函数，单测钉死「手选过的一个都不动」这条铁律）。
    /// 入参：当前存着什么（key = SettingsKeys，值为 nil / 空白表示没存过）。
    /// 返回：要改哪几处，顺序稳定（openai → deepseek → qwen），好让提示里那几行不会每次不一样。
    static func migrationToBestDefaultChanges(current: [String: String?]) -> [ModelChange] {
        var changes: [ModelChange] = []
        for provider in [LLMProvider.openai, .deepseek, .qwen] {
            guard let auto = autoPairs40[provider] else { continue }
            let keys = modelKeys(for: provider)
            // 没存过 = 出厂默认，和"停在自动默认上"是同一件事
            let polish = storedValue(current, keys.polish) ?? auto.polish
            let command = storedValue(current, keys.command) ?? auto.command
            guard polish == auto.polish, command == auto.command else { continue }
            let target = defaultModel(for: provider)
            if polish != target { changes.append(ModelChange(key: keys.polish, from: polish, to: target)) }
            if command != target { changes.append(ModelChange(key: keys.command, from: command, to: target)) }
        }
        return changes
    }

    /// 要写回的键值；空字典 = 什么都不用改。
    static func migrationToBestDefault(current: [String: String?]) -> [String: String] {
        var writes: [String: String] = [:]
        for change in migrationToBestDefaultChanges(current: current) {
            writes[change.key] = change.to
        }
        return writes
    }

    /// 把改动编码成一行存进设置：**只存型号名，不存句子**——句子要按看的时候那一刻的语言拼
    /// （见 CLAUDE.md「i18n 快照字符串」）。同一对只留一份（润色和指令往往换成同一个）。
    static func encodeModelChanges(_ changes: [ModelChange]) -> String {
        var pairs: [String] = []
        for change in changes {
            let pair = change.from + ">" + change.to
            if !pairs.contains(pair) { pairs.append(pair) }
        }
        return pairs.joined(separator: ",")
    }

    /// AI 页上那条一次性提示。nil = 没有可说的（没迁移过、或者用户已经点过「知道了」）。
    ///
    /// 为什么非说不可：4.0.0 的「快」档写进去的那一对，和出厂默认一字不差，迁移分不出
    /// 「停在默认」与「明确选过便宜档」。分不出就只能把改动摆在明面上——
    /// OpenAI 那一档 luna → sol 是约 20 倍的输入价差，而润色每句话都要跑一次。
    static func modelChangeNotice(_ raw: String) -> String? {
        let pairs = raw.split(separator: ",").compactMap { pair -> String? in
            let parts = pair.split(separator: ">", maxSplits: 1)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return parts[0] + " → " + parts[1]
        }
        guard !pairs.isEmpty else { return nil }
        let list = pairs.joined(separator: tr("、", ", "))
        // 一行结论 + 一颗「知道了」（Plan C 的边界状态预算）：为什么会变、怎么省钱
        // 各占一句话的那一版是一段话，用户扫一眼就跳过去了
        return tr("默认型号跟着升级换成了 \(list)，想省钱在「模型」里挑。",
                  "The default model moved up to \(list) - pick a cheaper one under Model to spend less.")
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
