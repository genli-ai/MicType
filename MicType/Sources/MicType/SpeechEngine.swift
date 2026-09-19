import Foundation

// MARK: - 识别引擎抽象
// 当前唯一实现是 QwenEngine；保留协议是为了将来接入其它引擎（如 FireRedASR）时即插即用。

/// 一次识别的结果。**永远不是"成功或失败"两档**：长音频按段识别，第 3 段炸了不等于
/// 前 2 段没说过——那正是 owner 说的"之前的语音都保留不下来"。所以这里同时带着
/// 「已经识别出来的文字」和「尾巴为什么没了」，由上层决定怎么交付。
struct TranscriptionOutcome {
    /// 已完成段落拼好的全文（可能为空串）
    let text: String
    /// 已完成的段数 / 计划总段数（未分段时都是 1）
    let completedSegments: Int
    let totalSegments: Int
    /// 尾巴没转完的原因：识别失败（带错误文案）或被用户叫停。nil = 全部跑完
    let failure: MTError?
    let cancelled: Bool

    /// 整段都转完了
    var isComplete: Bool { failure == nil && !cancelled }
    /// 交付了一部分：有文字，但尾巴没了 —— 界面上必须说清楚
    var isPartial: Bool { !isComplete && !text.isEmpty }
}

/// 在途识别的句柄：Esc 按下时叫停**下一段**。
/// 当前这一段停不下来（MLX 一次解码到底），所以"取消"的语义是"不再开新段"，
/// 而不是"立刻结束"——上层要照这个语义写文案。
final class TranscriptionHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledFlag = false

    /// 已经出结果的段数。只在主线程读写（引擎每完成一段回主线程更新一次），
    /// 供 Esc 那条路判断"有没有东西可交付"。
    private(set) var completedSegments = 0

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    func cancel() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
    }

    /// 引擎在主线程调用
    func noteSegmentCompleted() {
        completedSegments += 1
    }
}

protocol SpeechEngine: AnyObject {
    var engineName: String { get }
    var isModelAvailable: Bool { get }
    var isModelLoaded: Bool { get }
    func preload()
    func unloadModel()
    /// samples：16kHz 单声道 Float32。
    ///
    /// - language: 已经**锁定**的识别语言（英文全名，口径见 RecognitionLanguages.modelLanguage）。
    ///   nil = 按设置来（「自动」档交给引擎自己判）。录音中的预转写锁定过语言之后**必须**把它
    ///   传下来：松手后要转的那截尾巴通常只有十几秒，是整条链路上最短、最容易被判错语言的一段，
    ///   而判错语言正是"模型开始翻译 → 掉进复读"那条链的起点（探针里 11 分钟那次就是这么废的）。
    /// - previousText: 这段音频**之前**已经定稿的文字（预转写好的前半段）。只做跨段上下文的种子，
    ///   **绝不进 TranscriptionOutcome.text**——前后怎么拼由调用方负责，
    ///   引擎再拼一遍就等于把同一段话交付两遍。
    ///
    /// onSegment 每完成一段在主线程回调一次（参数是"到此为止拼好的全文"与段序号/总段数），
    /// completion 同样在主线程回调。返回的句柄用来叫停后续段落。
    @discardableResult
    func transcribe(samples: [Float],
                    language: String?,
                    previousText: String,
                    onSegment: ((String, Int, Int) -> Void)?,
                    completion: @escaping (TranscriptionOutcome) -> Void) -> TranscriptionHandle
}

extension SpeechEngine {

    /// 便利版：没有语言锁、也没有上文（短录音、连通性探针与单测走的都是这条）。
    /// 协议要求本身不许带默认值，所以补在这里——调用点不必为"本来就没有上文"写两个空参数。
    @discardableResult
    func transcribe(samples: [Float],
                    onSegment: ((String, Int, Int) -> Void)?,
                    completion: @escaping (TranscriptionOutcome) -> Void) -> TranscriptionHandle {
        transcribe(samples: samples, language: nil, previousText: "",
                   onSegment: onSegment, completion: completion)
    }
}
