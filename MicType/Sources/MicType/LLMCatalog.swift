import Foundation

// MARK: - 大模型型号目录（v4.0）

/// 「哪些服务商、哪些型号、默认用谁、接口地址怎么拼、谁不吃 temperature、坏了怎么跟用户说」
/// 全都收在这一个文件里。
/// 为什么单独成文件：这些是**随服务商换代而变**的知识，型号或端点一更新只该改这里；
/// 网络层（LLMClient）、设置界面、迁移逻辑都只读这里，不各自硬写型号名与 URL。
/// 目录本身只是快选与默认值——模型名输入框永远可以手填任意型号（自建网关、新发布的模型）。
enum LLMCatalog {

    // MARK: - 预设与默认

    /// 各档服务商的**默认型号**。4.0.1–5.0.5 润色和指令用同一个；5.0.6 起 OpenAI 这一档
    /// 润色单独换成 terra（见 openaiPolishModel），指令仍是 luna。
    ///
    /// **规矩（用户 2026-09-20 拍板，推翻 2026-09-19 那条「默认绝不能是便宜的那一档」）：
    /// 默认一律是这家「均衡偏快」的那一档，不是旗舰。**
    ///
    /// 推翻它的是实测数字（4.1.2/4.1.3 的日志）：润色是**每句话都要跑一次**的东西，
    /// 它的全部价值是顺手——qwen3.8-flash 润色 1.8–3.6 秒、指令 3.4 秒，用户的评价是"好用"；
    /// 同一条链路上 qwen3.8-max 要 4–12 秒，还撞得上 12 秒的润色超时（撞上就是这句话白说）。
    /// 一个更聪明但慢三倍、偶尔整句丢掉的润色，不是更好的默认值，是更差的产品。
    /// 想要旗舰的人在「模型」下拉里一眼就能选到（那一档标着「旗舰」）。
    /// OpenAI 语音指令的型号。
    static let openaiCommandModel = "gpt-5.6-luna"
    /// OpenAI 润色的型号（5.0.6 起）。依据是 iOS 2026-09-28 的 144 次保真评测（iOS DECISIONS L38）：
    /// 润色 terra 严格保真 80% vs luna 64%，意思级错误 1–2 次 vs 9 次，中位延迟只多 +180 ms。
    /// 指令不跟着换：同一轮评测里 terra 做指令质量没有提升、价格约 8 倍，所以指令仍是 luna。
    static let openaiPolishModel = "gpt-5.6-terra"
    // qwenDefaultModel（qwen3.8-flash）5.1.0 删掉：阿里云那一档整档移除（用户 2026-09-28 拍板）。

    /// 润色用哪个型号。**5.0.0 起这就是全部**：没有设置、没有下拉、没有输入框
    /// （用户 2026-09-22 拍板）。"挑型号"是一个用户没有依据、也不该被问的问题；
    /// 这几个值本来就是按实测挑出来的速度/质量平衡点（见上面那段注释）。
    ///
    /// 验证 Key 也拿这个型号去探（KeyEntryView）：润色是每句话都要跑的那一趟，
    /// Key 能用却开不了这个型号的话，用户说的第一句话就会失败。
    /// 5.1.0 起只剩 OpenAI 一档，参数留着是为了让调用方继续按"这一档"说话。
    static func polishDefault(for provider: LLMProvider) -> String { openaiPolishModel }

    /// 语音指令用哪个型号。
    static func commandDefault(for provider: LLMProvider) -> String { openaiCommandModel }

    // 「模型选单」5.0.0 整段删掉（ModelChoice / modelMenu / modelLabel / modelWrites /
    // selectedMenuModel / unifyModelWrites / modelKeys，以及 4.x 那三条型号迁移）：
    // 型号不再是一条设置，polishDefault / commandDefault 就是唯一的答案。
    // 5.0.6 删掉了原来的 `defaultModel(for:)`：润色与指令从这一版起不再是同一个型号，
    // 留一个不说是哪件事的"默认型号"只会让调用方拿错。

    // MARK: - 配置齐了没有

    /// AI（润色 + 语音指令）现在到底跑不跑得起来：引导最后一屏的两种收尾话术、
    /// 以及「没配 AI」的可见状态都据此二选一。三样都得有：
    ///   • 凭据——本机模型那一档的"空 Key"由 LLMClient.credential 判成**有**凭据，这里只收结论；
    ///   • 拼得出来的接口地址——被导入设置改成空串时就是没配好；
    ///   • 非空的润色型号——自定义端点与本机模型没有内置型号，用户没填就是没配好。
    /// 纯函数、不读全局状态：调用方把三样喂进来，单测才钉得住。
    static func aiReady(hasCredential: Bool, baseURL: String, polishModel: String) -> Bool {
        guard hasCredential else { return false }
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !polishModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 引导收尾那一行该说哪一种话。**5.0.0 只剩两档**：润色不再有开关，
    /// 所以「配齐了但润色关着」（commandsOnly）这一档不存在了。
    enum AIStatus: Equatable {
        /// 凭据、地址齐了：听写、润色、指令全都跑得起来
        case ready
        /// 还没填 Key（或者拼不出地址）——这一档下**连听写都不能用**，5.0.0 起识别也在云端
        case off
    }

    static func aiStatus(hasCredential: Bool, baseURL: String, polishModel: String) -> AIStatus {
        aiReady(hasCredential: hasCredential, baseURL: baseURL, polishModel: polishModel)
            ? .ready : .off
    }

    // MARK: - 一小时要花多少钱（识别 + 润色合计）
    //
    // 5.0.0–5.0.6 这个数摆在引导 ③ 的两张服务商卡片上（两家差着五倍）；5.1.0 只剩 OpenAI，
    // 它改由 Key 那颗 ⓘ 与验通之后的状态行念出来，出处仍然只有这一个。
    //
    // 两段费用的来路不一样，注释也要如实分开写：
    //   • 识别那一段是**查过官方价目页的**（2026-09-21，与 cloudASRPriceNote 同源）；
    //   • 润色那一段是**估算**：按普通语速约 150 词/分钟、润色一进一出约 2.5 倍输入 token，
    //     乘各家当前默认型号的 token 单价推出来。它比识别小一个数量级，估错也不改变结论
    //     （哪一家更贵），但**绝不许把它说成实测数字**。
    //
    // 界面上一律只说"约"，而且只保留一位小数（见 hourlyCostNote）：给一个 $1.1234 的数字，
    // 等于假装我们知道用户会说多久、说多密。

    /// 每小时录音的**识别**费用（美元）：实时 gpt-live-transcribe $0.017/分钟，
    /// 5.1.0 起每句话松手后还要整段再传一次 gpt-transcribe $0.0045/分钟（混合转写，
    /// OpenAI 模型页 2026-09-28 查）——两段都按录音时长计费，合计 × 60 ≈ $1.29/小时。
    /// 整段先赢、实时还没 commit 时实时会被掐掉、这一句不计实时的钱，所以这是偏高的那一边的估计。
    static func asrHourlyUSD(provider: LLMProvider) -> Double { (0.017 + 0.0045) * 60 }

    /// 每小时录音的**润色**费用（美元，估算，见上面那段注释）
    ///
    /// OpenAI 5.0.6 从 0.08 改成 0.40：润色换成 gpt-5.6-terra（Fast 档）。**估算**，出处是
    /// iOS DECISIONS L38 的评测账单——terra Fast 档约 $1.1 / 千次润色 × sentencesPerHour 360 次
    /// ≈ $0.40/小时。不是 Mac 上的实测账单。
    static func polishHourlyUSD(provider: LLMProvider) -> Double { 0.40 }

    /// 两段加起来：引导卡片与设置状态行念的就是这个数
    static func hourlyUSD(provider: LLMProvider) -> Double {
        asrHourlyUSD(provider: provider) + polishHourlyUSD(provider: provider)
    }

    /// 「约 $1.1/小时」。**只留一位小数**，而且永远带"约"。纯函数，单测钉住格式。
    static func hourlyCostNote(provider: LLMProvider) -> String {
        let text = String(format: "$%.1f", hourlyUSD(provider: provider))
        return tr("约 \(text)/小时", "about \(text)/hour")
    }

    /// 一小时能说多少句。**30 字一句、每句连着说约 10 秒**（含停顿）——这个数只用来
    /// 把"每小时多少钱"翻译成用户真正能感知的那个单位（他不会按小时说话，他按句说话）。
    static let sentencesPerHour: Double = 360

    /// 一句话大约多少钱（美元）
    static func perSentenceUSD(provider: LLMProvider) -> Double {
        hourlyUSD(provider: provider) / sentencesPerHour
    }

    /// 「每句话约 $0.003」。**不写成"分钱"**：中文里"分"既可能被读成人民币、也可能被读成
    /// 美分，而这笔钱是用户拿自己的卡直接付给服务商的——写清货币符号比读着顺重要。
    /// 纯函数，单测钉住格式。
    static func perSentenceCostNote(provider: LLMProvider) -> String {
        let text = String(format: "$%.3f", perSentenceUSD(provider: provider))
        return tr("每句话约 \(text)", "about \(text) per sentence")
    }

    // MARK: - 去哪儿申请 Key / 固定的 Key 与费用说法

    // 引导 ③ 的两张服务商卡片（audienceNote「海外信用卡 / 支付宝可用」、strengthNote「专名更准 /
    // 更便宜、更快」）5.1.0 删掉：只剩一家，没有要比的了。

    /// 「去申请 Key ↗」指向的页面（设置页 Key 那一行右边那颗按钮）。
    static func apiKeyConsoleURL(for provider: LLMProvider) -> String {
        "https://platform.openai.com/api-keys"
    }

    // KeyConsole（.single / .choices）5.0.4 为阿里云那两个站（International / China）加的，
    // 5.1.0 随阿里云一起删掉：只剩一个地址，按钮点了就开（apiKeyConsoleURL）。

    /// 那颗按钮上的字（设置页与引导 ③ 共用，只写一处）
    static var getAKeyLabel: String { tr("去申请 Key ↗", "Get a key ↗") }

    // MARK: - 引导 ③ 的申请步骤（编号 + 每步一个「打开 ↗」）

    /// 一步：一句能照着做的话，外加它要打开的那几个页面。
    ///
    /// 为什么值得一张表：这是**整个产品最容易卡死人的一分钟**——用户手上没有 Key，
    /// 而"去哪儿点"这件事我们知道、他不知道。写成一行"去服务商控制台申请一把 Key"
    /// 等于把最难的一步留给他自己。链接与文字都只写这一处（引导 ③ 是唯一的渲染点）。
    struct ConsoleStep: Equatable {
        let text: String
        /// 这一步能打开的页面。空 = 这一步不用离开 MicType。
        let links: [Link]

        struct Link: Equatable {
            let label: String
            let url: String
        }
    }

    /// 拿 Key 的那几步（纯函数，单测钉住"每一步都有话、链接都是 https"）。
    ///
    /// **三步封顶**（5.0.1）：原先最后一步是「回到这里粘贴」——粘贴框就在这几行字底下，
    /// 光标都在那儿，用一整行告诉他"回来"是在凑步骤。
    static func consoleSteps(for provider: LLMProvider) -> [ConsoleStep] {
        [
            ConsoleStep(text: tr("注册", "Sign up"),
                        links: [.init(label: tr("打开", "Open"),
                                      url: "https://platform.openai.com/")]),
            ConsoleStep(text: tr("充值", "Add credit"),
                        links: [.init(label: tr("打开", "Open"),
                                      url: "https://platform.openai.com/settings/organization/billing/overview")]),
            // 5.3.0 去掉「，复制」（设计稿 Onboarding-2）：复制之后那一步是 App 自己做的——
            // 这一屏出现时会读一次剪贴板，认出 sk- 开头的就替他填进去（ClipboardKey）
            ConsoleStep(text: tr("创建 API Key", "Create an API key"),
                        links: [.init(label: tr("打开", "Open"),
                                      url: apiKeyConsoleURL(for: provider))]),
        ]
    }

    /// Key 怎么存 / 钱怎么付。**设置页与引导页必须逐字用这两句**（同一个事实只写一处）。
    static var keyStorageNote: String {
        tr("Key 存在 macOS 钥匙串里，不写进文件，也不随设置导出。",
           "Your key lives in the macOS Keychain: never written to a file, never included in a settings export.")
    }
    static var billingNote: String {
        tr("费用由服务商直接结给你，MicType 不经手、不加价，也不代发你的请求。",
           "You pay the provider directly. MicType takes no cut and never proxies your requests.")
    }
    // MARK: - 接口地址

    // QwenRegion / qwenBaseURL（阿里云的区域端点与 Base URL 推导）5.1.0 删掉。
    // LocalRuntime（Ollama / LM Studio）5.0.0 删掉：本机大模型那一档没有了。

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
    /// 为什么要过滤：OpenAI 的 /models 有上百条，全塞进下拉框等于没有下拉框。
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
        // DashScope 兼容模式那一档（qwenEnableSearch，只发 enable_search）5.1.0 随阿里云删掉
        /// OpenRouter：`plugins:[{id:"web"}]`
        case openrouterPlugin
        /// 这个端点没有内建搜索 → **整段只留一行说明，连开关都不摆**（4.1.1），绝不假装能用
        case unsupported
    }

    static func searchStyle(provider: LLMProvider, baseURL: String) -> WebSearchStyle {
        let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?.lowercased() ?? ""
        if host == "openrouter.ai" || host.hasSuffix(".openrouter.ai") { return .openrouterPlugin }
        // web_search 是 Responses 独有；OpenAI 档指向第三方网关时只有 chat/completions，没有它
        return LLMClient.usesResponsesAPI(baseURL: baseURL) ? .openaiResponsesTool : .unsupported
    }

    /// 联网搜索的单价——**全 App 唯一出处**。设置页开关旁与隐私说明（PrivacyCopy.webSearchBilled）
    /// 都引用它，不许各写各的：两处价钱对不上的时候，用户没法知道哪句算数。
    ///
    /// 4.1.1 起默认**开着**（用户 2026-09-20 拍板：支持联网搜索的服务商一律默认开，
    /// 不支持的那几档连开关都不摆）。这句话跟着改：写着"默认关闭"而实际开着，
    /// 比不说更糟——用户按这句话判断自己有没有在花这笔钱。
    /// 5.0.2 砍短：括号里那句「OpenAI 按 $10 / 1000 次计」是算给我们自己看的，
    /// 「默认开启」也和引它的那句「永远开」重复。它现在只出现在 Key 那颗 ⓘ 里，
    /// 而那颗气泡这一版刚接下了两句从关于页搬来的话——每个字都要付房租。
    static var webSearchPriceNote: String { tr("每次约 $0.01 外加 token 费用。",
                                       "about $0.01 per search plus tokens.") }

    /// 第三方网关（OpenRouter）那一档的联网搜索价钱。**我们报不出一个准数**：它按网关自己的
    /// 价目结算——编一个数字比不给数字糟得多，所以只说"按服务商计费"。
    /// （4.1–5.0 阿里云那一档也念这一句，5.1.0 那一档删掉了。）
    static var providerBilledSearchNote: String { tr("按服务商自己的价目计费。",
                                            "billed at your provider's own rates.") }

    /// 这一档的开关旁边该摆哪句价钱。nil = 这个端点压根没有联网搜索（开关也不摆）。
    /// 纯函数：价钱与"有没有这个功能"必须同源，否则会出现"这家没有搜索"+"每次 $0.01"并排。
    static func webSearchPriceNote(style: WebSearchStyle) -> String? {
        switch style {
        case .openaiResponsesTool: return webSearchPriceNote
        case .openrouterPlugin: return providerBilledSearchNote
        case .unsupported: return nil
        }
    }

    /// Fast 档的代价：token 单价翻倍。**单价只写这一处**——4.1.0 之前开关标题里还硬写着
    /// 一个「2 倍」，改价就会有两个数字打架。
    ///
    /// 4.1.6 起没有「优先处理」这个开关了（用户 2026-09-21 拍板：OpenAI 官方接口一律走 Fast），
    /// 所以这句话不再说"默认关闭"，而且它现在只被 PrivacyCopy.fastTier 引用——写成能接在
    /// 「…一律走 Fast 档：」后面的半句（英文首字母小写），免得拼出来中间冒出一个大写字母。
    /// 云端识别的单价（**全 App 唯一出处**）。查证日期 2026-09-21，来自 OpenAI 官方价目页。
    /// （4.3–5.0 这里还有阿里云那一档的 $0.13/小时，5.1.0 删掉。）
    static func cloudASRPriceNote(provider: CloudASRProvider) -> String {
        tr("约 $0.017/分钟", "about $0.017/min")
    }

    static var fastTierPriceNote: String { tr("延迟更低更稳，token 单价约 2 倍。",
                                      "lower, steadier latency at about 2x the token price.") }

    /// 服务商回传的 service_tier 原值算不算"真的跑在优先档上"。
    /// OpenAI 回 "fast"，别的兼容端点习惯叫 "priority"——后者也得算数，
    /// 否则真跑在优先档上的那一次会被染成橙色的"被降级了"。纯函数。
    static func servedPriorityTier(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "fast" || value == "priority"
    }

    /// service_tier 原值 → 界面说法。认不出的档位**原样显示**：硬翻成"普通档"是在编，
    /// 原值摆出来用户至少能拿去问服务商。纯函数。
    ///
    /// 4.1.6 起界面上**暂时没有地方**摆它：「优先处理」那一段连同"上一次跑在哪一档"一起
    /// 删了（OpenAI 官方接口恒走 Fast，用户不再被问这个问题），而诊断信息是要整段贴给别人的，
    /// 必须是固定英文、报原值。留着它是因为"回传的档位怎么念"只该有一个说法——
    /// 下一次要在界面上说这件事时，别再现造一套词（单测仍然逐档钉着它）。
    static func serviceTierName(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fast", "priority": return tr("优先档", "the priority tier")
        case "default": return tr("普通档", "the standard tier")
        case "flex": return tr("弹性档（更慢、更便宜）", "the flex tier (slower and cheaper)")
        default: return raw
        }
    }

    /// 悬浮窗/历史里那句「已联网 · 3 来源」。0 条来源也要说「已联网」——
    /// 有的端点（OpenRouter 之类）不回传来源，用户仍该知道这次调用花了搜索的钱。
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
    /// 只有 gpt-6-astra 不支持 none（发了会 400 → 退到 "low"）。5.0.5 以前整条 gpt-6 线都排除，
    /// 5.0.6 按官方文档 + iOS 实测收窄：gpt-6-luna / gpt-6-sol 都接受 none。
    static func supportsEffortNone(_ model: String) -> Bool {
        !model.lowercased().contains("gpt-6-astra")
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

    // 4.x 的型号迁移（migrationTo56 / migrationToBestDefault / migrationToFastDefault，
    // 连同 ModelChange / encodeModelChanges / modelChangeNotice 与那几个 flag key）
    // 5.0.0 整段删掉：型号已经不是一条设置，没有东西可迁、也没有改动要向用户交代。

    // MARK: - 错误话术

    /// 一条可以直接摆给用户看的失败说明 + 这条错误在悬浮窗上带哪颗按钮。
    ///
    /// 5.3.0 起（UX 方案 §3 H）：**一句话 ≤ 16 字，细节进日志**。5.2.0 之前句尾还拼着
    /// 服务商的原话（截 60 字）和充值页的整串 URL（fullText），悬浮窗两行都装不下；
    /// 现在原话由调用方记日志（AgentService.send），充值页变成一颗「去充值」按钮（.addCredit）。
    struct ErrorCopy: Equatable {
        let text: String
        /// 悬浮窗上那颗按钮：401 → 打开设置；余额不足 → 去充值；其余 → 关闭
        let action: OverlayErrorAction

        /// 有下一步链接的那一档（目前只有余额不足）指向哪儿；没有则 nil
        var actionURL: String? { action == .addCredit ? LLMCatalog.billingURL : nil }
    }

    /// HTTP 失败 → 双语话术（纯函数，单测钉死每个分支）。
    /// - status：HTTP 状态码（照样写进那句话：用户抄给别人问的时候，这个数最值钱）
    /// - provider：5.1.0 起只有 OpenAI；留着参数是为了"Key 永不串槽"那条纪律（调用处点名）
    /// - code：响应里的 `error.code` / `error.type`（429 靠它区分限流与余额不足）
    /// - message：响应里的 `error.message`——**只用来判类别，不上屏**（原话由调用方进日志）
    static func describeHTTPError(status: Int, provider: LLMProvider,
                                  code: String?, message: String?) -> ErrorCopy {
        let hay = ((code ?? "") + " " + (message ?? "")).lowercased()

        switch status {
        case 401:
            return ErrorCopy(text: UserMessage.keyRejected, action: .openSettings)
        case 403:
            // OpenAI 的 403 几乎总是国家/地区封锁（用户在 UAE，这条命中率不低）。
            // 5.1.0 阿里云那一档删掉之后没有另一家可以指给他——**不编一个不存在的下一步**
            return ErrorCopy(text: UserMessage.regionBlocked(status), action: .dismiss)
        case 404:
            return ErrorCopy(text: UserMessage.modelNotFound(status), action: .dismiss)
        case 429:
            // 「等一会儿」和「去充钱」是两件完全不同的事，并成一句话用户根本不知道该干什么。
            if hay.contains("insufficient_quota") || hay.contains("quota") || hay.contains("billing")
                || hay.contains("balance") {
                return ErrorCopy(text: UserMessage.outOfCredit(status), action: .addCredit)
            }
            return ErrorCopy(text: UserMessage.rateLimited(status), action: .dismiss)
        case 503:
            return ErrorCopy(text: UserMessage.serviceBusy(status), action: .dismiss)
        default:
            return ErrorCopy(text: UserMessage.serverError(status), action: .dismiss)
        }
    }

    /// 超时话术。
    /// - retried: 这一趟之前真的重发过一次。4.1.1 起润色与指令都**只发一次**
    ///   （PolishService / AgentService 的 networkRetries = 0），而超时又是 UAE 这条链路上
    ///   最常见的那一句——无条件写着"已重试一次"就是每天在对用户说假话，日志里也一样。
    ///   仍会重试的只剩验证 / 测试那几条路。
    ///   不指认"网络"：4.1.2 的日志里那几趟超时，服务端自己就算了 ~17 s（思考模式），
    ///   我们只知道"没等到"，就只说这个。
    static func timeoutCopy(retried: Bool = false) -> ErrorCopy {
        ErrorCopy(text: retried ? UserMessage.timedOutRetried : UserMessage.timedOut, action: .dismiss)
    }

    /// 「去充值」指向哪个控制台。5.1.0 起只有 OpenAI 一档，永远有这条地址。
    /// （阿里云那一档没有可以打包票的充值地址，当年宁可不给按钮；那一档已删。）
    // qwenUnverifiedHost401（阿里云接入地址还没试对时的 401 话术）5.1.0 删掉。
    static let billingURL = "https://platform.openai.com/settings/organization/billing"
}
