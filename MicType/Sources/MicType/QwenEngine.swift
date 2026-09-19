import Foundation

// MARK: - Qwen 模型选项

struct QwenModelOption {
    let repo: String       // HuggingFace 仓库 ID
    let title: String
    let sizeNote: String
    let languagesNote: String
}

enum QwenModels {

    /// 模型清单的来源。**目录驱动**：清单来自仓库根的 model-catalog.json（远端 → 缓存 →
    /// App 内置 → 代码字面表），发新模型不需要发新版 App。
    /// 这里留一个可替换的闭包只为单测能喂一份假目录，产品路径永远是 ModelCatalogStore。
    static var catalogProvider: () -> [CatalogModel] = { ModelCatalogStore.shared.models }

    /// 界面上可选的模型。目录为空（不该发生）时退回代码里的字面表；
    /// 需要更高 App 版本的条目**不进下拉框**——列出一个装了也跑不起来的模型是在骗用户，
    /// 它们改由「需要更新 MicType」那条提示负责（见 ModelUpgrader）。
    static var all: [QwenModelOption] {
        let models = availableModels
        return models.map { option(for: $0) }
    }

    /// 目录里当前 App 能跑的模型
    static var availableModels: [CatalogModel] {
        let listed = catalogProvider()
        let models = listed.isEmpty ? ModelCatalog.builtIn.models : listed
        let version = UpdateChecker.currentVersion
        let runnable = models.filter {
            AppVersionCompare.satisfiesMinimum(appVersion: version, minimum: $0.minAppVersion)
        }
        // 一条都跑不了时宁可把目录原样列出来（老 App + 全新目录），也不要给用户一个空下拉框
        return runnable.isEmpty ? models : runnable
    }

    static func option(for model: CatalogModel) -> QwenModelOption {
        QwenModelOption(repo: model.repo,
                        title: model.displayName.localized,
                        sizeNote: sizeNote(bytes: model.sizeBytes),
                        languagesNote: model.languagesNote.localized)
    }

    /// 字节数 → 界面上那句「约 862 MB」。十进制口径（和 HF 页面、Finder 一致）。
    /// 0 / 负数（目录漏写 sizeBytes）→ 空字符串，绝不显示「约 0 MB」。
    ///
    /// GB 保留两位小数：这一行是用户决定要不要花流量的唯一依据，1.7B 那一档是 1.61 GB，
    /// 按一位小数写成「1.6 GB」会和 0.6B 的 8bit 档（1.01 GB）一样含糊——差了 600 MB 的两档
    /// 在界面上必须看得出来。（历史上这里还写死过一句「约 1.1 GB」，比四舍五入更糟。）
    static func sizeNote(bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        if bytes >= 1_000_000_000 {
            let gb = Double(bytes) / 1_000_000_000
            return tr("约 ", "~") + String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / 1_000_000
        return tr("约 ", "~") + String(format: "%.0f MB", mb)
    }

    /// 模型目录下每一个存在的仓库目录（含只下了一半的）。清理要看的是磁盘真相，
    /// 不是设置里写了什么——半个下载也会占几百 MB。
    static func repoDirectories() -> [String] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.modelsDir,
                                                     includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return dirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent.replacingOccurrences(of: "__", with: "/") }
    }

    /// 下载进行中的标记文件名。为什么需要它：下载是逐文件写进最终位置的，
    /// model.safetensors 写完、tokenizer/config 还没下完的那几十秒里，
    /// 「目录里有 model.safetensors」就已经成立了——这一刻按热键，引擎会去加载一个缺文件的模型，
    /// 报一句看不懂的错。下载一开始就写这个标记、全部下完才删，带标记的目录一律不算"已装"。
    static let incompleteMarkerName = ".incomplete"

    /// 这个仓库目录里是不是一份**下完整**的模型。
    /// 老用户（这个标记出现之前装好的模型）目录里没有标记 → 照样算完整，不会被判成要重下。
    static func isFullyDownloaded(repo: String) -> Bool {
        let dir = localDirectory(for: repo)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.appendingPathComponent(incompleteMarkerName).path) else {
            return false
        }
        return fm.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
    }

    /// 一个模型目录占了多少字节（日志用；算不出来给 0）
    static func directorySize(repo: String) -> Int64 {
        let dir = localDirectory(for: repo)
        guard let files = try? FileManager.default.subpathsOfDirectory(atPath: dir.path) else { return 0 }
        return files.reduce(Int64(0)) { total, sub in
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(sub).path)
            return total + ((attrs?[.size] as? Int64) ?? 0)
        }
    }

    static let defaultRepo = "mlx-community/Qwen3-ASR-0.6B-6bit"

    /// 一段音频该给多少 token 预算：**秒数 × 8 + 64**。
    ///
    /// 为什么必须显式传：库的默认值是 4096，而它内部又取 min(maxTokens, ceil(秒数*20)+64)——
    /// 密集语音超过约 3.4 分钟（4096/20）就会**静默截断且不报错**。
    /// 为什么是 8 不是 20：探针实测峰值出字速率 英语 3.5 字/秒、阿语 2.9、中文 2.7，
    /// 8 已经是两倍余量；留的余量越大，一段跑飞的复读就烧得越久（4096 那次就是这么烧完的）。
    /// 纯函数，可单测。
    static func segmentMaxTokens(seconds: Double) -> Int {
        Int(ceil(max(0, seconds) * 8)) + 64
    }

    /// 模型仓库在本地的存放目录
    static func localDirectory(for repo: String) -> URL {
        Paths.modelsDir.appendingPathComponent(
            repo.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
    }
}

#if arch(arm64)

import MLXASR

/// Qwen3-ASR 本地识别引擎（MLX，Apple Silicon 专属）
final class QwenEngine: SpeechEngine, @unchecked Sendable {

    static let shared = QwenEngine()
    private init() {}

    var engineName: String { "Qwen3-ASR" }

    private var modelDirectory: URL {
        QwenModels.localDirectory(for: Settings.shared.qwenModelRepo)
    }

    /// 模型能不能用。三个条件缺一不可：权重在、config.json 在、**没有 .incomplete 标记**——
    /// 下到一半的目录里 model.safetensors 可能已经就位，按这个去加载只会在用户开口之后报错。
    var isModelAvailable: Bool {
        let dir = modelDirectory
        return QwenModels.isFullyDownloaded(repo: Settings.shared.qwenModelRepo)
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path)
    }

    // 以下状态只在主线程读写
    private var loadTask: Task<Qwen3ASRSTT, Error>?
    private var loadedDirPath: String?
    private var readyDirPath: String?

    var isModelLoaded: Bool { loadTask != nil }
    var isModelReady: Bool {
        let dir = modelDirectory.path
        return loadTask != nil && loadedDirPath == dir && readyDirPath == dir
    }

    /// 主线程调用：获取（或创建）模型加载任务，含 Metal 预热
    private func ensureLoadTask() -> Task<Qwen3ASRSTT, Error> {
        let dir = modelDirectory
        let dirPath = dir.path
        if let task = loadTask, loadedDirPath == dir.path {
            return task
        }
        loadTask = nil
        readyDirPath = nil
        let task = Task {
            try await Qwen3ASRSTT.loadWithWarmup(from: dir)
        }
        loadTask = task
        loadedDirPath = dirPath
        Task { [weak self] in
            do {
                _ = try await task.value
                guard let engine = self else { return }
                await MainActor.run {
                    guard engine.loadedDirPath == dirPath else { return }
                    engine.readyDirPath = dirPath
                }
            } catch {
                // transcribe() reports the concrete error and clears the failed task.
            }
        }
        return task
    }

    /// HF 上的 Qwen3-ASR 量化仓库普遍缺 tokenizer.json（swift-transformers 必需），
    /// 从 App 自带资源里补一份到模型目录
    private func ensureTokenizerFile() -> MTError? {
        ensureTokenizerFile(in: modelDirectory)
    }

    /// 同上，但对**任意**模型目录生效——升级校验要在切换设置之前先验新模型那一份
    private func ensureTokenizerFile(in directory: URL) -> MTError? {
        let dest = directory.appendingPathComponent("tokenizer.json")
        if FileManager.default.fileExists(atPath: dest.path) { return nil }
        guard let bundled = Bundle.main.url(forResource: "tokenizer", withExtension: "json",
                                            subdirectory: "QwenTokenizer") else {
            return MTError(tr("缺少分词器资源。请先运行 scripts/Generate Qwen Tokenizer.command 再重新安装", "Tokenizer resource missing — run scripts/Generate Qwen Tokenizer.command and reinstall"))
        }
        do {
            try FileManager.default.copyItem(at: bundled, to: dest)
            return nil
        } catch {
            return MTError(tr("无法写入 tokenizer.json：", "Cannot write tokenizer.json: ") + error.localizedDescription)
        }
    }

    /// 词汇表直接作为热词上下文喂给模型（decoder 层的第一道纠正）。
    /// 前缀与分隔符跟着识别语言走（"常用词汇：" / "Common terms: "），实现见 RecognitionLanguages。
    private static func hotwordContext(terms: [String], languageCode: String) -> String? {
        RecognitionLanguages.hotwordContext(terms: terms, languageCode: languageCode)
    }

    /// 伪流式预览：对"到此为止"的一段音频跑一遍识别，结果**只用于悬浮窗灰字**，永不插入。
    ///
    /// 三条纪律：
    /// 1. 只在模型已就绪（isModelReady）时才跑——预览绝不触发模型加载，也绝不替用户等十几秒；
    /// 2. GPU 串行由 Qwen3ASRSTT 这个 actor 本身保证：预览和最终那一遍永远排队，不会并发抢 GPU；
    /// 3. 返回的 Task 可取消——松手时立刻取消，解码循环里的 Task.checkCancellation() 会让出
    ///    actor，最终识别最多多等一次 prefill，不会被整段预览堵住。
    ///
    /// completion 在主线程回调：成功给（文本, 耗时毫秒），失败或被取消不回调（取消是正常路径）。
    @discardableResult
    func transcribePartial(samples: [Float],
                           completion: @escaping (String?, Int) -> Void) -> Task<Void, Never>? {
        guard isModelReady, let load = loadTask else { return nil }
        let vocabTerms = Settings.shared.vocabularyTerms
        let languageCode = Settings.shared.recognitionLanguage
        let context = Self.hotwordContext(terms: vocabTerms, languageCode: languageCode)
        let language = Settings.shared.recognitionModelLanguage
        return Task {
            guard let stt = try? await load.value else {
                // 加载失败的善后（清缓存、报错）留给正式 transcribe，预览这边安静退场
                DispatchQueue.main.async { completion(nil, 0) }
                return
            }
            if Task.isCancelled { return }
            let started = DispatchTime.now()
            do {
                let result = try await stt.transcribe(audio: samples, language: language,
                                                      context: context, temperature: 0.0)
                let elapsed = Log.ms(since: started)
                if Task.isCancelled { return }
                let cleaned = TextPostProcessor.cleanTranscript(result.text)
                let text = TextPostProcessor.isVocabEcho(cleaned, terms: vocabTerms) ? "" : cleaned
                DispatchQueue.main.async { completion(text, elapsed) }
            } catch {
                let elapsed = Log.ms(since: started)
                // 取消是正常路径（用户松手了），不报错也不刷新草稿
                if Task.isCancelled { return }
                Log.warn("Partial transcription failed: " + String(error.localizedDescription.prefix(80)))
                DispatchQueue.main.async { completion(nil, elapsed) }
            }
        }
    }

    /// 录音**还在继续**时，把已经切好的一整段音频转成最终文字（预转写 / progressive）。
    ///
    /// 和 transcribePartial（悬浮窗灰字）完全是两回事：那一遍是给眼睛看的草稿，这一遍的结果
    /// 会进最终文本，所以逐字走和松手后那一遍相同的口径——同样的 maxTokens 公式、同样的
    /// cleanTranscript、同样的热词复读丢弃。松手时只剩最后一小截要转（3 分钟口述从等约 10 s
    /// 变成等约 1 s），而峰值内存永远只是"一段"。
    ///
    /// 纪律与预览一致：模型没就绪就不跑（返回 nil，调用方安静退场，绝不替用户等加载），
    /// 返回的 Task 可取消。completion 在主线程：(文字, 这一段检测到的语言)，失败给 (nil, nil)。
    @discardableResult
    func transcribeLiveSegment(samples: [Float],
                               language: String?,
                               previousText: String,
                               completion: @escaping (String?, String?) -> Void) -> Task<Void, Never>? {
        guard isModelReady, let load = loadTask else { return nil }
        let vocabTerms = Settings.shared.vocabularyTerms
        let languageCode = Settings.shared.recognitionLanguage
        let context = RecognitionLanguages.segmentContext(terms: vocabTerms,
                                                          languageCode: languageCode,
                                                          previousText: previousText)
        let seconds = Double(samples.count) / 16000.0
        let maxTokens = QwenModels.segmentMaxTokens(seconds: seconds)
        return Task {
            guard let stt = try? await load.value else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }
            if Task.isCancelled { return }
            let started = DispatchTime.now()
            do {
                let result = try await stt.transcribe(audio: samples, language: language,
                                                      context: context, maxTokens: maxTokens,
                                                      temperature: 0.0)
                if Task.isCancelled { return }
                let cleaned = TextPostProcessor.cleanTranscript(result.text)
                let text = TextPostProcessor.isVocabEcho(cleaned, terms: vocabTerms) ? "" : cleaned
                let detected = RecognitionLanguages.lockableModelLanguage(result.language)
                Log.info("Live segment ms=\(Log.ms(since: started))"
                         + " audio=\(String(format: "%.1f", seconds))s chars=\(text.count)")
                // 这一段的 mask / KV 立刻还回去：录音还在继续，内存要一直停在"一段"的量级
                Qwen3ASRSTT.flushMemoryPool()
                DispatchQueue.main.async { completion(text, detected) }
            } catch {
                if Task.isCancelled { return }
                Log.warn("Live segment failed: " + String(error.localizedDescription.prefix(80)))
                DispatchQueue.main.async { completion(nil, nil) }
            }
        }
    }

    func preload() {
        guard isModelAvailable, ensureTokenizerFile() == nil else { return }
        _ = ensureLoadTask()
    }

    /// 升级校验的最后一关：从**指定目录**（还没被选中的那个新模型）真跑一遍完整识别。
    ///
    /// 为什么非要真跑：文件齐、大小对、config.json 能解析，都只证明「下载没断」，
    /// 证明不了权重能在这台机器上加载（量化格式不认、缺 tensor、MLX 版本对不上都是这么炸的）。
    /// 一段 1 秒的合成音频跑完整条 加载 → log-mel → encoder → 解码 的链路，成本一次几秒，
    /// 换来的是「敢不敢删掉旧模型」的依据——旧模型是用户唯一的退路，删错了他就没法听写了。
    ///
    /// 用一个**一次性实例**，不碰 loadTask：校验期间用户随时可能照常听写，正在用的那份模型
    /// 一根头发都不许动。校验结束 flushMemoryPool() 把这几百 MB 还回去。
    /// completion 在主线程回调，nil = 通过。
    func verifyModel(directory: URL, samples: [Float], completion: @escaping (MTError?) -> Void) {
        if let tokErr = ensureTokenizerFile(in: directory) {
            DispatchQueue.main.async { completion(tokErr) }
            return
        }
        Task {
            let started = DispatchTime.now()
            do {
                let stt = try await Qwen3ASRSTT.loadWithWarmup(from: directory)
                // temperature > 0 是**校验的关键**，不是随手填的：贪心解码（0.0）对着一段
                // 没有内容的合成音会立刻吐 EOS，一个采样步都不走，等于只验了"模型加载得起来"。
                // 给一点温度才会真的走完采样循环，把解码那几个 kernel 也跑一遍——
                // 而"敢不敢删旧模型"正是押在这一遍上。
                let result = try await stt.transcribe(audio: samples, language: nil,
                                                     context: nil, temperature: 0.3)
                // 只看「跑通了」，不看它把这段合成音听成了什么——合成音本来就没有内容。
                // 长度进日志（不进内容），便于排查「加载成功但解码空转」这类怪事。
                Log.info("Model verify transcription ok ms=\(Log.ms(since: started)) chars=\(result.text.count)")
                Qwen3ASRSTT.flushMemoryPool()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                let message = String(error.localizedDescription.prefix(120))
                Log.warn("Model verify transcription failed ms=\(Log.ms(since: started)): \(message)")
                Qwen3ASRSTT.flushMemoryPool()
                DispatchQueue.main.async {
                    completion(MTError(tr("新模型无法加载：", "The new model failed to load: ") + message))
                }
            }
        }
    }

    func unloadModel() {
        loadTask = nil
        loadedDirPath = nil
        readyDirPath = nil
        Qwen3ASRSTT.flushMemoryPool()
    }

    /// 一开口就失败（模型没下载 / 分词器缺失 / 加载不起来）：一个字都没有的结果
    private static func failed(_ error: MTError) -> TranscriptionOutcome {
        TranscriptionOutcome(text: "", completedSegments: 0, totalSegments: 0,
                             failure: error, cancelled: false)
    }

    /// 识别整段录音。**长音频按段顺序跑**（分段规则见 AudioSegmenter，brief §3.1–3.3）：
    ///
    ///   • 每段显式传 `QwenModels.segmentMaxTokens(seconds:)` ＝ **秒数 × 8 + 64**。
    ///     库的默认值是 4096，而它内部又取 `min(maxTokens, ceil(秒数*20)+64)`——密集语音超过
    ///     约 3.4 分钟就会撞上 4096 那道暗闸，**静默截断且不报错**。我们传的这个数比库内部的
    ///     ×20 紧 2.5 倍，所以它才是**实际生效**的那道上限；8 这个系数的实测依据见 :101-110
    ///     （峰值出字速率 英语 3.5 字/秒，已留两倍余量）。换更"出字密集"的语言或模型时要复核它。
    ///   • 段间 `flushMemoryPool()`：否则每段的 mask / KV 叠着涨，长音频吃到几个 GB。
    ///   • 上一段的尾巴进下一段的 context（热词在前），见 RecognitionLanguages.segmentContext；
    ///     `previousText` 是这条上下文链的**种子**——录音中预转写好的前半段从这里接进来，
    ///     否则整条链路上最后那道接缝（尾巴的第一段）是唯一没有上文的一段。
    ///   • 每完成一段就回调一次：文字先落到界面上，用户看得见进度；失败或被叫停时
    ///     已经出来的段落照常交付（TranscriptionOutcome.isPartial）。
    @discardableResult
    func transcribe(samples: [Float],
                    language: String?,
                    previousText: String,
                    onSegment: ((String, Int, Int) -> Void)?,
                    completion: @escaping (TranscriptionOutcome) -> Void) -> TranscriptionHandle {
        let handle = TranscriptionHandle()
        guard isModelAvailable else {
            DispatchQueue.main.async {
                completion(Self.failed(MTError(tr("Qwen 模型未下载，请在 设置 → 识别 中下载", "Qwen model not downloaded — see Settings → Recognition"))))
            }
            return handle
        }
        if let tokErr = ensureTokenizerFile() {
            DispatchQueue.main.async { completion(Self.failed(tokErr)) }
            return handle
        }

        let vocabTerms = Settings.shared.vocabularyTerms
        let languageCode = Settings.shared.recognitionLanguage
        // 英文全名或 nil，见 RecognitionLanguages.modelLanguage（语言代码会被原样拼进 prompt）。
        // 调用方传下来的语言锁优先：「自动」档下 Settings 这一侧恒为 nil，而录音中的预转写
        // 可能已经替这一轮锁定了语言——尾巴要接着用同一个，不能自己重新检测一遍。
        let sessionLanguage = language ?? Settings.shared.recognitionModelLanguage

        let load = ensureLoadTask()
        Task {
            // 第一步：等待模型加载。失败要清掉缓存的 Task，否则之后永远复用失败结果
            let stt: Qwen3ASRSTT
            do {
                stt = try await load.value
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    self?.loadTask = nil
                    self?.loadedDirPath = nil
                    self?.readyDirPath = nil
                    completion(Self.failed(MTError(tr("Qwen 模型加载失败：", "Qwen model failed to load: ") + String(message.prefix(120)))))
                }
                return
            }
            await MainActor.run { [weak self] in
                self?.readyDirPath = self?.loadedDirPath
            }

            // 第二步：规划切点（≤90s 只有一段，行为与分段之前完全一致）
            let plan = AudioSegmenter.plan(samples: samples)
            let total = plan.count
            if total > 1 {
                Log.info("Segmented transcription segments=\(total)"
                         + " audio=\(String(format: "%.1f", Double(samples.count) / 16000.0))s")
            }
            var parts: [String] = []
            var joined = ""
            var failure: MTError?
            // 语言锁：第一段自动检测出什么语言，后面几段就**显式**按那个语言转。
            // 探针里那次 11 分钟的失败就是从语言漂移开始的——模型锁在英语上，开始把阿语
            // 翻译成英语，翻着翻着掉进复读循环，直到烧完 token 预算。用户显式选过语言、
            // 或录音中的预转写已经锁定过语言时，sessionLanguage 一开始就不是 nil，
            // 这里只管"自动 + 这一轮还没人锁过"那一档。
            var lockedLanguage = sessionLanguage
            for (index, range) in plan.enumerated() {
                // 取消的语义是"不再开新段"：正在解码的这一段停不下来（MLX 一次解码到底）
                if handle.isCancelled { break }
                let chunk = total == 1 ? samples : Array(samples[range])
                let seconds = Double(chunk.count) / 16000.0
                let maxTokens = QwenModels.segmentMaxTokens(seconds: seconds)
                // 跨段上下文从 previousText（录音中已定稿的前半段）起算：第一段的上文因此
                // 不再是空串。parts / joined 仍从空开始——交付的文本里绝不能带上这段前缀。
                let context = RecognitionLanguages.segmentContext(
                    terms: vocabTerms,
                    languageCode: languageCode,
                    previousText: TextPostProcessor.joinSegments([previousText, joined]))
                let started = DispatchTime.now()
                do {
                    // language 为 nil 时走模型自动检测（默认）；用户显式选过、或第一段已经
                    // 检测出语言（语言锁）就传英文全名
                    let result = try await stt.transcribe(
                        audio: chunk,
                        language: lockedLanguage,
                        context: context,
                        maxTokens: maxTokens,
                        temperature: 0.0
                    )
                    if lockedLanguage == nil, total > 1,
                       let detected = RecognitionLanguages.lockableModelLanguage(result.language) {
                        lockedLanguage = detected
                        Log.info("Segment language locked to \(detected)")
                    }
                    // 复读折叠等清理**按段做、拼接之前**：一段跑飞不该污染整篇
                    let cleaned = TextPostProcessor.cleanTranscript(result.text)
                    let text = TextPostProcessor.isVocabEcho(cleaned, terms: vocabTerms) ? "" : cleaned
                    parts.append(text)
                    joined = TextPostProcessor.joinSegments(parts)
                } catch {
                    failure = MTError(tr("Qwen 识别失败：", "Qwen transcription failed: ")
                                      + String(error.localizedDescription.prefix(120)))
                    Log.error("Segment \(index + 1)/\(total) failed after \(Log.ms(since: started))ms")
                    break
                }
                if total > 1 {
                    Log.info("Segment \(index + 1)/\(total) ms=\(Log.ms(since: started))"
                             + " audio=\(String(format: "%.1f", seconds))s chars=\(parts[index].count)")
                    // 把这一段的 mask / KV 还回去，长音频的峰值内存才是"一段"而不是"整篇"
                    Qwen3ASRSTT.flushMemoryPool()
                }
                let snapshot = joined
                let done = index + 1
                await MainActor.run {
                    handle.noteSegmentCompleted()
                    onSegment?(snapshot, done, total)
                }
            }

            let stoppedEarly = parts.count < total
            let outcome = TranscriptionOutcome(text: joined,
                                               completedSegments: parts.count,
                                               totalSegments: total,
                                               failure: failure,
                                               cancelled: failure == nil && stoppedEarly)
            DispatchQueue.main.async {
                // 刚换过模型的话，「删掉旧模型」就等这一刻：新模型在真实听写里跑通过一次，
                // 旧的那份才不再是退路。绝不在切换设置的当下就删（见 ModelUpgrader）。
                if outcome.failure == nil, !outcome.text.isEmpty {
                    ModelUpgrader.shared.noteSuccessfulTranscription()
                }
                completion(outcome)
            }
        }
        return handle
    }
}

#else

/// Intel 机型占位实现：V2 的 Qwen/MLX 引擎只支持 Apple Silicon。
final class QwenEngine: SpeechEngine {
    static let shared = QwenEngine()
    private init() {}

    var engineName: String { "Qwen3-ASR" }
    var isModelAvailable: Bool { false }
    var isModelLoaded: Bool { false }
    var isModelReady: Bool { false }
    func preload() {}
    func transcribePartial(samples: [Float],
                           completion: @escaping (String?, Int) -> Void) -> Task<Void, Never>? { nil }
    @discardableResult
    func transcribeLiveSegment(samples: [Float], language: String?, previousText: String,
                               completion: @escaping (String?, String?) -> Void) -> Task<Void, Never>? { nil }
    func unloadModel() {}
    /// Intel 上没有引擎可验：直接失败，绝不让升级流程以为「验过了」而去删旧模型
    func verifyModel(directory: URL, samples: [Float], completion: @escaping (MTError?) -> Void) {
        DispatchQueue.main.async {
            completion(MTError(tr("MicType 仅支持 Apple Silicon", "MicType requires Apple Silicon")))
        }
    }
    @discardableResult
    func transcribe(samples: [Float],
                    language: String?,
                    previousText: String,
                    onSegment: ((String, Int, Int) -> Void)?,
                    completion: @escaping (TranscriptionOutcome) -> Void) -> TranscriptionHandle {
        let handle = TranscriptionHandle()
        DispatchQueue.main.async {
            completion(TranscriptionOutcome(
                text: "", completedSegments: 0, totalSegments: 0,
                failure: MTError(tr("MicType 仅支持 Apple Silicon", "MicType requires Apple Silicon")),
                cancelled: false))
        }
        return handle
    }
}

#endif
