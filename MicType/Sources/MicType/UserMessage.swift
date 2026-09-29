import Foundation

// MARK: - 错误与告知：全 App 的集中表（5.3.0，UX 方案 §3 H）

/// 悬浮窗、Key 状态行上出现的**每一句"不顺利"**都从这里拿。
///
/// 规矩（用户 2026-09-29 定，由 UserMessageCopyTests 钉死）：
///   • 一句话：中文 ≤ 16 字、英文 ≤ 8 个词；
///   • 不写「请」「抱歉」，不写长破折号解释（「——」），不写感叹号；
///   • 能动手修的，配一颗按钮（按钮由调用处点名，见 OverlayErrorAction），文案里不再写"去设置"；
///   • **细节进日志，不进悬浮窗**：服务商的原话、错误码、系统的 localizedDescription
///     全部由产生错误的那一层记 Log.warn，屏幕上只留结论。
///
/// 为什么非收成一张表：5.2.0 之前这些话散在 DictationController、CloudASR、LLMCatalog、
/// AgentService 四处，最长的一句 60 多字（"指令模式需配置 API Key；纯语音输入请「轻点」…"），
/// 悬浮窗两行都装不下。散着写就没有东西量得到下一句——和 SettingsCopy 当年是同一个病。
///
/// 带参数的那几句（HTTP 状态码、段号）照样在这里，测试喂代表性的参数去量。
enum UserMessage {

    // MARK: 缺东西（按钮：打开设置）

    /// 没有 Key。5.1.0 起只有 OpenAI 一家，所以直接点名
    static var keyMissing: String { tr("还没填 OpenAI Key", "No OpenAI key yet.") }

    /// Key 被拒（401 / 实时那条路的 unauthorized）
    static var keyRejected: String { tr("Key 无效或已撤销 (401)", "Key invalid or revoked (401).") }

    /// 实时识别那条路的 unauthorized（没有 HTTP 状态码可报）
    static var keyRejectedRealtime: String { tr("Key 无效或已撤销", "Key invalid or revoked.") }

    /// 按住说指令但没有 Key。识别也要这把 Key，所以这条实际上很难走到——
    /// 但走到了就要把手势教对（铁律：无 Key 长按 → 明确提示纯输入请轻点，不做剪贴板兜底）
    static var commandNeedsKey: String { tr("指令需要 Key，听写轻点", "Commands need a key. Tap to dictate.") }

    // MARK: 系统权限（引导会自己打开，按钮：关闭）

    static var accessibilityOff: String { tr("辅助功能未开启", "Accessibility is off.") }
    static var microphoneOff: String { tr("麦克风未授权", "Microphone access is off.") }
    /// 首次授权之后这一次录音不可靠（系统弹窗抢了焦点），要他再按一次
    static var microphoneJustGranted: String { tr("麦克风已授权，再按一次", "Microphone on. Press again.") }

    // MARK: 网络与服务商

    static var offline: String { tr("没有网络，连上再试", "Offline. Connect and try again.") }
    static var networkError: String { tr("网络出错，再试一次", "Network error. Try again.") }
    static var timedOut: String { tr("请求超时", "Request timed out.") }
    /// 验证 / 测试那几条路还会重试一次，只有它们配得上这一句
    static var timedOutRetried: String { tr("请求超时，已重试一次", "Timed out, retried once.") }
    static var recognitionTimedOut: String { tr("识别超时，再说一次", "Recognition timed out. Say it again.") }
    static var connectionDropped: String { tr("连接中断，再说一次", "Connection dropped. Say it again.") }
    static var recognitionError: String { tr("识别出错，再说一次", "Recognition error. Say it again.") }
    static var noRealtimeModel: String { tr("没有实时识别模型", "No realtime speech model.") }

    static func regionBlocked(_ status: Int) -> String {
        tr("所在地区不支持 (\(status))", "Not available in your region (\(status)).")
    }
    static func keyNotAllowed(_ status: Int) -> String {
        tr("Key 无权用此模型 (\(status))", "Key can't use this model (\(status)).")
    }
    static func modelNotFound(_ status: Int) -> String {
        tr("找不到模型 (\(status))", "Model not found (\(status)).")
    }
    static func outOfCredit(_ status: Int) -> String {
        tr("余额不足 (\(status))", "Out of credit (\(status)).")
    }
    static func rateLimited(_ status: Int) -> String {
        tr("请求太频繁，稍后再说 (\(status))", "Rate limited. Try again shortly (\(status)).")
    }
    static func serviceBusy(_ status: Int) -> String {
        tr("服务繁忙，稍后再试 (\(status))", "Service busy. Try again shortly (\(status)).")
    }
    static func requestRejected(_ status: Int) -> String {
        tr("请求被拒 (\(status))", "Request rejected (\(status)).")
    }
    static func serverError(_ status: Int) -> String {
        tr("服务出错 (\(status))", "Server error (\(status)).")
    }

    // MARK: 返回的东西不对

    static var emptyResponse: String { tr("没有收到响应", "No response came back.") }
    static var unreadableResponse: String { tr("返回格式无法解析", "Couldn't read the response.") }
    static var modelReturnedNothing: String { tr("模型没有返回内容", "The model returned nothing.") }
    static var noTranscript: String { tr("没有返回识别文本", "No transcript came back.") }
    static var outputTruncated: String { tr("输出被截断，说短一点", "Output cut off. Say less.") }
    static var audioTooLarge: String { tr("音频超过 25 MB 上限", "Audio is over 25 MB.") }
    static var invalidEndpoint: String { tr("接口地址无效", "Invalid endpoint URL.") }
    static var endpointIncomplete: String { tr("接口地址不完整", "Endpoint URL is incomplete.") }
    static var noModelName: String { tr("还没填模型名", "No model name yet.") }
    static var unknownError: String { tr("未知错误", "Unknown error.") }

    // MARK: 识别这一轮

    /// 重试也没成：不报技术细节，他已经等了两趟（原因在日志里）
    static var nothingCameBack: String { tr("没识别到，再说一次", "Nothing came back. Try again.") }
    /// 实时失败、正拿整段音频再走一次同步接口（「想」形态上的附注）
    static var retryingRecognition: String { tr("识别失败，重试中", "Recognition failed. Retrying.") }
    static var nothingHeard: String { tr("没有听到内容", "Nothing heard.") }
    static var tooQuiet: String { tr("声音太小，靠近些再说", "Too quiet. Move closer.") }
    static var commandCutShort: String { tr("指令被截断，再按住说", "Command cut short. Hold and retry.") }
    static var commandFailed: String { tr("指令失败", "Command failed.") }
    static var draftFailed: String { tr("草拟失败", "Draft failed.") }
    static var selectionUnreadable: String { tr("读不到选区，重选再试", "Can't read the selection. Reselect it.") }

    static func stoppedAtPart(_ done: Int, of total: Int) -> String {
        tr("已停在第 \(done)/\(total) 段", "Stopped at part \(done) of \(total).")
    }
    static func partFailed(_ part: Int) -> String {
        tr("第 \(part) 段失败，前面已输入", "Part \(part) failed. Earlier parts inserted.")
    }

    // MARK: 录音设备（AudioRecorder；细节在它自己的日志行里）

    static var noMicrophone: String { tr("没有可用的麦克风", "No microphone found.") }
    static var recordingSetupFailed: String { tr("录音初始化失败", "Couldn't set up recording.") }
    static var recordingStartFailed: String { tr("无法启动录音", "Couldn't start recording.") }
    static var audioDeviceChanged: String { tr("录音设备已变更，已提前结束", "Audio device changed. Stopped early.") }

    // MARK: 录音这一轮的附注

    static var recordingLimitReached: String { tr("已到录音上限", "Reached the recording limit.") }
    static var silenceStopped: String { tr("静音，已自动结束", "Silence detected. Stopped.") }

    // MARK: 润色

    static var polishFailed: String { tr("润色失败，已给原文", "Polish failed. Raw text inserted.") }
    static var polishDrifted: String { tr("润色偏离原意，已给原文", "Polish drifted. Raw text inserted.") }

    // MARK: 投递（字没落进输入框）

    static var passwordField: String { tr("密码框不能听写，已复制", "Password field. Text copied.") }
    static var noTextField: String { tr("这里没有输入框，已复制", "No text field here. Text copied.") }
    static var copiedPressPaste: String { tr("已复制，⌘V 粘贴", "Copied. Press ⌘V to paste.") }
    static var windowChanged: String { tr("窗口已切换，⌘V 粘贴", "Window changed. Press ⌘V to paste.") }

    // MARK: 换回原文

    static var revertAppGone: String { tr("没能切回原应用", "Couldn't switch back to the app.") }
    static var rawCopiedPressPaste: String { tr("原文已复制，⌘V 粘贴", "Raw text copied. Press ⌘V.") }

    // MARK: 手势与节奏

    static var busyEscCancels: String { tr("处理中，Esc 可取消", "Busy. Esc cancels.") }
    static var justFinishedPressAgain: String { tr("上一轮刚结束，再按一次", "Just finished. Press again.") }

    // MARK: Key 验证那一行（设置 / 引导 ②）

    /// 验证失败、钥匙串里原来那把没动：接在失败原因后面的半句
    static var previousKeyKept: String { tr("仍用上一把 Key", "Still using the previous key.") }
    static var providerChangedPasteAgain: String { tr("再粘一次这把 Key", "Paste the key again.") }
    static var keyRemoved: String { tr("Key 已从钥匙串删除", "Key removed from Keychain.") }

    // MARK: 每周一句（5.4.0，豁免长度规矩）

    /// 每周第一次启动闪的那一句：「上周说了 43 分钟，打出 6,200 字」。
    /// **不在 `all` 里、豁免 ≤ 16 字 / 8 词**（任务书 5.4.0 点名豁免，UserMessageCopyTests 另量它）：
    /// 它不是一句"不顺利"，而是两个数字——拆短了就只剩一个数。数字的写法与设置状态卡同一处出处（UsageFormat）
    static func weeklyRecap(_ week: UsageWeek) -> String {
        let minutes = UsageFormat.minutes(week), chars = UsageFormat.chars(week)
        return tr("上周说了 \(minutes)，打出 \(chars)", "Last week: \(minutes) spoken, \(chars) typed")
    }

    /// 豁免长度规矩的句子（带参数的喂代表性的参数）。其余规矩（不写请 / 抱歉 / 感叹号、双语都写）照样量
    static var exemptFromLength: [String] {
        [weeklyRecap(UsageWeek(seconds: 43 * 60, chars: 6_200, sentences: 120, costUSD: 0.5))]
    }

    // MARK: 量表（UserMessageCopyTests 逐条量）

    /// 表里每一句（带参数的那几句喂代表性的参数）。**新加一句就加进这里**，否则量不到它
    static var all: [String] {
        [keyMissing, keyRejected, keyRejectedRealtime, commandNeedsKey,
         accessibilityOff, microphoneOff, microphoneJustGranted,
         offline, networkError, timedOut, timedOutRetried, recognitionTimedOut,
         connectionDropped, recognitionError, noRealtimeModel,
         regionBlocked(403), keyNotAllowed(403), modelNotFound(404), outOfCredit(429),
         rateLimited(429), serviceBusy(503), requestRejected(400), serverError(500),
         emptyResponse, unreadableResponse, modelReturnedNothing, noTranscript, outputTruncated,
         audioTooLarge, invalidEndpoint, endpointIncomplete, noModelName, unknownError,
         nothingCameBack, retryingRecognition, nothingHeard, tooQuiet, commandCutShort,
         commandFailed, draftFailed, selectionUnreadable,
         stoppedAtPart(12, of: 13), partFailed(12),
         noMicrophone, recordingSetupFailed, recordingStartFailed, audioDeviceChanged,
         recordingLimitReached, silenceStopped,
         polishFailed, polishDrifted,
         passwordField, noTextField, copiedPressPaste, windowChanged,
         revertAppGone, rawCopiedPressPaste,
         busyEscCancels, justFinishedPressAgain,
         previousKeyKept, providerChangedPasteAgain, keyRemoved]
    }
}
