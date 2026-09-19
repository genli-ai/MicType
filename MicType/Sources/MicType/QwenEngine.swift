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
    static func sizeNote(bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        if bytes >= 1_000_000_000 {
            let gb = Double(bytes) / 1_000_000_000
            return tr("约 ", "~") + String(format: "%.1f GB", gb)
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

    /// 已经下载完（目录里有 model.safetensors）的仓库 ID
    static func installedRepos() -> [String] {
        let fm = FileManager.default
        return repoDirectories().filter { repo in
            fm.fileExists(atPath: localDirectory(for: repo).appendingPathComponent("model.safetensors").path)
        }
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
    /// 更大的那一档。阿语上的差距远大于中英：Fleurs-ar 词错率 25.5%（0.6B）→ 17.0%（1.7B），
    /// Common Voice ar 46.0% → 38.0%（技术报告）。所以选阿语时要主动推荐它，而不是默默用小模型。
    static let largeRepo = "mlx-community/Qwen3-ASR-1.7B-4bit"

    /// 「该不该推荐换大模型」的判定：只在**用户显式选了阿语**且当前还是小模型时为真。
    /// 纯函数、可单测；只推荐不自动换——换模型要下载 1.1 GB，这种事永远由用户点。
    static func recommendsLargeModel(languageCode: String, currentRepo: String) -> Bool {
        languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ar"
            && currentRepo != largeRepo
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

    var isModelAvailable: Bool {
        let dir = modelDirectory
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
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
                let result = try await stt.transcribe(audio: samples, language: nil,
                                                     context: nil, temperature: 0.0)
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

    func transcribe(samples: [Float], completion: @escaping (Result<String, MTError>) -> Void) {
        guard isModelAvailable else {
            DispatchQueue.main.async {
                completion(.failure(MTError(tr("Qwen 模型未下载，请在 设置 → 识别 中下载", "Qwen model not downloaded — see Settings → Recognition"))))
            }
            return
        }
        if let tokErr = ensureTokenizerFile() {
            DispatchQueue.main.async { completion(.failure(tokErr)) }
            return
        }

        let vocabTerms = Settings.shared.vocabularyTerms
        let languageCode = Settings.shared.recognitionLanguage
        let context = Self.hotwordContext(terms: vocabTerms, languageCode: languageCode)
        // 英文全名或 nil，见 RecognitionLanguages.modelLanguage（语言代码会被原样拼进 prompt）
        let language = Settings.shared.recognitionModelLanguage

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
                    completion(.failure(MTError(tr("Qwen 模型加载失败：", "Qwen model failed to load: ") + String(message.prefix(120)))))
                }
                return
            }
            await MainActor.run { [weak self] in
                self?.readyDirPath = self?.loadedDirPath
            }
            // 第二步：识别。失败不影响已加载的模型
            do {
                // language 为 nil 时走模型自动检测（默认）；用户显式选过就传英文全名——
                // mlx-swift-asr 把它原样拼进 prompt，传 "ar" 会变成字面的「language ar」
                let result = try await stt.transcribe(
                    audio: samples,
                    language: language,
                    context: context,
                    temperature: 0.0
                )
                let cleaned = TextPostProcessor.cleanTranscript(result.text)
                let final = TextPostProcessor.isVocabEcho(cleaned, terms: vocabTerms) ? "" : cleaned
                DispatchQueue.main.async {
                    // 刚换过模型的话，「删掉旧模型」就等这一刻：新模型在真实听写里跑通过一次，
                    // 旧的那份才不再是退路。绝不在切换设置的当下就删（见 ModelUpgrader）。
                    ModelUpgrader.shared.noteSuccessfulTranscription()
                    completion(.success(final))
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    completion(.failure(MTError(tr("Qwen 识别失败：", "Qwen transcription failed: ") + String(message.prefix(120)))))
                }
            }
        }
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
    func unloadModel() {}
    /// Intel 上没有引擎可验：直接失败，绝不让升级流程以为「验过了」而去删旧模型
    func verifyModel(directory: URL, samples: [Float], completion: @escaping (MTError?) -> Void) {
        DispatchQueue.main.async {
            completion(MTError(tr("MicType 仅支持 Apple Silicon", "MicType requires Apple Silicon")))
        }
    }
    func transcribe(samples: [Float], completion: @escaping (Result<String, MTError>) -> Void) {
        DispatchQueue.main.async {
            completion(.failure(MTError(tr("MicType 仅支持 Apple Silicon", "MicType requires Apple Silicon"))))
        }
    }
}

#endif
