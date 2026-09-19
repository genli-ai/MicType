import Foundation

// MARK: - 大模型型号目录（v4.0）

/// 「哪些型号、默认用谁、谁不吃 temperature、坏了怎么跟用户说」全都收在这一个文件里。
/// 为什么单独成文件：这些是**随服务商换代而变**的知识，型号一更新只该改这里；
/// 网络层（LLMClient）、设置界面、迁移逻辑都只读这里，不各自硬写型号名。
/// 目录本身只是快选与默认值——模型名输入框永远可以手填任意型号（自建网关、新发布的模型）。
enum LLMCatalog {

    // MARK: - 预设与默认

    /// OpenAI 快选（2026-09 在售主力）。luna 成本敏感、terra 平衡、sol 旗舰、astra 最强。
    static let openaiPresets = ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-6-astra"]
    /// DeepSeek 快选。老的 deepseek-v4-flash / deepseek-chat / deepseek-reasoner 已全部下线（见迁移）。
    static let deepseekPresets = ["deepseek-flash", "deepseek-v4-pro"]

    /// 润色高频、只是改写 → 用最便宜的一档；指令低频、要质量 → 往上一档。
    /// （旗舰放在每句话都要跑的润色路径上是纯烧钱：luna 与 sol 的输入价差 20 倍。）
    static let openaiPolishDefault = "gpt-5.6-luna"
    static let openaiCommandDefault = "gpt-5.6-terra"
    static let deepseekPolishDefault = "deepseek-flash"
    static let deepseekCommandDefault = "deepseek-v4-pro"

    static func presets(for provider: LLMProvider) -> [String] {
        switch provider {
        case .openai: return openaiPresets
        case .deepseek: return deepseekPresets
        }
    }

    static func polishDefault(for provider: LLMProvider) -> String {
        switch provider {
        case .openai: return openaiPolishDefault
        case .deepseek: return deepseekPolishDefault
        }
    }

    static func commandDefault(for provider: LLMProvider) -> String {
        switch provider {
        case .openai: return openaiCommandDefault
        case .deepseek: return deepseekCommandDefault
        }
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
            // 用户在 UAE，这一条命中率不低：OpenAI 对部分国家/地区直接 403。
            return ErrorCopy(text: tr("你所在的国家/地区不支持这个服务 (403)。可以改用 DeepSeek，或在设置里填一个自定义端点",
                                      "This service is not supported in your country or region (403). Switch to DeepSeek, or point MicType at a custom endpoint in Settings") + detail,
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
                                 actionLabel: tr("去充值", "Add credit"),
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

    /// 超时话术（已经重试过一趟才会走到这里）
    static func timeoutCopy() -> ErrorCopy {
        ErrorCopy(text: tr("请求超时（已重试一次，网络到 API 太慢）",
                           "Request timed out (retried once — the network to the API is too slow)"),
                  actionLabel: nil, actionURL: nil)
    }

    private static func billingURL(for provider: LLMProvider) -> String {
        switch provider {
        case .openai: return "https://platform.openai.com/settings/organization/billing"
        case .deepseek: return "https://platform.deepseek.com/top_up"
        }
    }
}
