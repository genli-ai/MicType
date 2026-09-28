import Foundation

// MARK: - 整段为准、实时兜底：这一句用哪条通道的字（5.1.0，移植自 iOS DECISIONS L39）
//
// 松手之后两条通道**同时**出发：实时通道收尾（它的音频在说话时已经传完了），
// 同一段录音再整段上传一次（gpt-transcribe）。谁的字进输入框由下面这个纯函数说了算。
//
// 为什么整段为准（用户 2026-09-28 拍板「准确率第一」）：公开集 110 段、11.4 分钟中文 / 中英混说
// （**就在这台 Mac mini 上测的**，docs/from-ios-260928/ASR-LIVE-VS-BATCH-BENCH_260928.md）
// 整段 gpt-transcribe 字错率 6.2%，实时 gpt-live-transcribe 9.0%——错字少约三成，
// 实时错的多是同音实词替换；代价是整段比实时终稿晚到中位 184 ms / p90 469 ms。
//
// 与 iOS 的差别（主会话 2026-09-28 定）：
//   • 没有规则 1（松手时实时积压 > 1.5 秒就不等实时）：Mac 的客户端没有积压计数，
//     有线 / Wi-Fi 上积压也不是问题；
//   • 没有「两条通道文字系统打架 → 无提示重试」与「都判出界 → 直接采用整段」两条：
//     那两条属于 iOS 按「我说的语言」发 `languages` 提示的那一套，Mac 不发这个提示；
//   • 换成更简单的一条：两条都能用、而主导文字系统不同 → 用整段（记一行日志）。
//     **阿拉伯语永远不算"不能用"**：它是必须支持的输入语言（用户在 UAE）。
enum HybridSelection {

    /// 整段在实时终稿之后还能晚到多久：0.8 秒 + 每秒录音 0.025 秒，最多 2 秒。
    ///
    /// 0.8 秒 ≈ 公开集里整段比实时晚到的 p90（469 ms）再留余量——好网络下整段几乎总在窗口内；
    /// 按录音长度加：实时终稿与长度无关（约 0.7 秒），整段却是约 0.78 秒 + 每秒录音 0.023 秒，
    /// 固定 0.8 秒会让 30 秒以上的句子按设计就用不上更准的那一条；2 秒封顶（48 秒录音到顶）
    /// 限住多等的时间。常量与 iOS `RealtimeTuning.hybridBatchWindow` 逐项相同。
    static let windowBase: TimeInterval = 0.8
    static let windowPerAudioSecond: TimeInterval = 0.025
    static let windowMax: TimeInterval = 2.0

    static func window(audioSeconds: Double) -> TimeInterval {
        min(windowMax, windowBase + windowPerAudioSecond * max(0, audioSeconds))
    }

    /// 超过这么长的录音不跑混合：只走实时（整段只在实时失败时才作为退路上传）。
    /// 为什么是 60 秒：窗口 48 秒就到顶了，再长的句子整段几乎总是迟到，白传一趟既费上行也费钱；
    /// 而超过 150 秒的录音本来就要分段串行上传，那条路不动（主会话 2026-09-28 定）。
    static let maxAudioSeconds: Double = 60

    /// 一条通道到这一刻的状态（文字已经过本地清理）
    enum Lane: Equatable {
        /// 还在跑
        case pending
        /// 有字
        case usable
        /// 服务商回了，但清理之后一个字都没有（没听清）
        case empty
        /// 没回来：网络 / HTTP 错误、终稿超时、握手被拒
        case failed
        /// 这一句压根没有这条通道
        case absent
    }

    enum Step: Equatable {
        case useBatch
        case useRealtime
        /// 两条都还在跑：等先到的那条
        case waitForEither
        /// 整段已经出局，实时那条由它自己的超时兜着
        case waitForRealtime
        /// nil = 等到它落地为止（由它自己的请求超时兜着）；有值 = 规则 2 窗口还剩多久
        case waitForBatch(window: TimeInterval?)
        /// 两条都没字，但至少有一条是"回了、没听清"：交出空文本，下游说「没听清」
        case noSpeech
        /// 两条都失败：走原来那条失败出路
        case failure
    }

    /// 规则（iOS L39 的 2–4 条 + Mac 的文字系统那一条）：
    ///   0. 两条都能用、主导文字系统不同 → 整段（Mac 专有，见文件头）；
    ///   2. 实时终稿到了 → 再给整段一个窗口：窗口内到 → 整段，窗口过了 → 实时（整段迟到）；
    ///      整段先到且能用 → 立刻用整段（按规则 2 它反正会赢，再等实时只是多等）；
    ///   3. 实时失败 / 超时 / 没字 → 等整段到底（它自己的请求超时）；
    ///   4. 两条都不能用 → 没听清 / 失败。
    /// - sinceRealtimeFinal: 实时终稿落地至今多少秒（没落地 = nil）；只在实时能用时读
    /// - scriptsDiffer: 两条的主导文字系统不同（任一条太短判不出 = false）；只在两条都能用时读
    static func next(realtime: Lane, batch: Lane, sinceRealtimeFinal: TimeInterval?,
                     audioSeconds: Double, scriptsDiffer: Bool = false) -> Step {
        if realtime == .usable, batch == .usable, scriptsDiffer { return .useBatch }   // 规则 0
        let window = window(audioSeconds: audioSeconds)
        if realtime == .usable, let since = sinceRealtimeFinal, since >= window {
            return .useRealtime   // 规则 2：窗口过了——这时才落地的整段算迟到，不管它说了什么
        }
        if batch == .usable { return .useBatch }
        if batch == .pending {
            switch realtime {
            case .pending: return .waitForEither
            case .usable: return .waitForBatch(window: max(0, window - (sinceRealtimeFinal ?? 0)))
            case .empty, .failed, .absent: return .waitForBatch(window: nil)   // 规则 3
            }
        }
        // 整段出局了（没字 / 失败 / 没有这条）：只剩实时
        switch realtime {
        case .pending: return .waitForRealtime
        case .usable: return .useRealtime
        case .empty, .failed, .absent:
            return (realtime == .empty || batch == .empty) ? .noSpeech : .failure   // 规则 4
        }
    }

    // MARK: 主导文字系统

    enum Script: Equatable {
        case han, latin, arabic, other
    }

    /// 字母最多的那种文字系统（数字、标点、空白不计），与润色保真那道闸门同一套计数
    /// （PolishFidelity.scriptCounts）。假名、谚文、西里尔字母都归 `.other`。
    /// 字母不足 4 个 → nil（太短，不判）；平局取汉字 > 拉丁 > 阿语 > 其他的顺序，结果稳定。
    static func dominantScript(_ text: String) -> Script? {
        let c = PolishFidelity.scriptCounts(text)
        guard c.total >= 4 else { return nil }
        let ranked: [(Script, Int)] = [(.han, c.han), (.latin, c.latin), (.arabic, c.arabic),
                                       (.other, c.kana + c.hangul + c.cyrillic)]
        // max(by:) 平局时保留先出现的那个——也就是上面这张表的顺序
        return ranked.max { $0.1 < $1.1 }?.0
    }

    /// 两段文字的主导文字系统不同吗（任一段判不出 = 不算不同）
    static func scriptsDiffer(_ a: String, _ b: String) -> Bool {
        guard let x = dominantScript(a), let y = dominantScript(b) else { return false }
        return x != y
    }
}
