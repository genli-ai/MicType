import Foundation
import Combine

// MARK: - 识别模型升级
//
// 要解决的问题：识别模型是这个产品唯一会被时代抛下的零件。更好的模型出来了，用户既不该自己去
// HuggingFace 翻仓库名，也不该在硬盘上留着两三份 800 MB 的旧权重。
//
// 因此这里只做三件事，且顺序不许换：
//   1. **提示**（目录里有更好的 / 已装仓库有新修订）——非模态横幅 + 菜单栏一条，永不弹窗打断；
//   2. **一键装**（下到新仓库自己的目录 → 校验 → 原子切换设置）——换不换永远是用户点的；
//   3. **清理**（删旧模型）——只在新模型**真实听写成功过一次之后**才动手。
//
// 为什么第 3 步要等：旧模型是用户唯一的退路。下载完整、能加载，都不等于在他的机器上、他的
// 麦克风上真的出字。等一次真实成功再删，最坏情况只是多占一次磁盘；反过来最坏情况是他明天
// 开会前发现听写坏了、而旧模型已经被我们删了。
//
// 失败一律回滚：校验不过 → 设置一个字不改（新文件留在旁边，下次重试能续传），横幅如实说明原因。

/// 「该不该提示升级」的结论。纯数据，可单测。
enum ModelUpgradeDecision: Equatable {
    /// 没什么可做的
    case none
    /// 目录里有更值得用的模型（换仓库）
    case upgrade(repo: String)
    /// 同一个仓库在 HF 上有新修订（重新下载同一个目录）
    case refresh(repo: String)
    /// 目录里那个更好的模型要求更新的 App 版本——这时只能去更新 MicType
    case needsAppUpdate(repo: String, minAppVersion: String)
}

/// 升级判定与清理选择的纯函数层。**不碰磁盘、不碰网络、不碰 UserDefaults**，全部可单测：
/// 这两个判断一个决定要不要花用户 800 MB 流量，一个决定删不删他的模型，不允许「大概是对的」。
enum ModelUpgradeLogic {

    /// 判定矩阵。
    ///
    /// - installedRepo: 当前选中的仓库（设置里的值）
    /// - catalog: 目录里的模型
    /// - appVersion: 正在跑的 App 版本
    /// - languageCode: 用户选的识别语言（"" = 自动）
    /// - revisionUpdateAvailable: 已装仓库在 HF 上是否有新修订（走现成的 sha 比对）
    /// - dismissedRepo: 用户点过「以后再说」的那个仓库（只压提示，菜单栏入口仍在）
    ///
    /// 两条克制原则写在判断里：
    ///   • 用户为某语言专门选了一档（如阿语选 1.7B，目录里标着 recommendedFor: ["ar"]），
    ///     就**不再**拿通用推荐档去劝他换回来——那是替用户做主；
    ///   • 目标模型要求更高的 App 版本时，只说「需要更新 MicType」，绝不假装能装。
    static func decide(installedRepo: String,
                       catalog: [CatalogModel],
                       appVersion: String,
                       languageCode: String,
                       revisionUpdateAvailable: Bool,
                       dismissedRepo: String?) -> ModelUpgradeDecision {
        let installed = installedRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        let installedEntry = catalog.first { $0.repo == installed }
        let target = catalog.first { $0.recommended } ?? catalog.first

        if let target = target, target.repo != installed {
            // 用户的这一档是为他选的语言准备的 → 不劝他换
            let keptForLanguage = installedEntry?.isRecommended(forLanguage: languageCode) ?? false
            if !keptForLanguage && dismissedRepo != target.repo {
                if AppVersionCompare.satisfiesMinimum(appVersion: appVersion,
                                                      minimum: target.minAppVersion) {
                    return .upgrade(repo: target.repo)
                }
                return .needsAppUpdate(repo: target.repo, minAppVersion: target.minAppVersion)
            }
        }

        // 没有更好的可换（或被上面两条压住）时，才看已装仓库本身有没有新修订
        if revisionUpdateAvailable, !installed.isEmpty {
            return .refresh(repo: installed)
        }
        return .none
    }

    /// 该删哪些模型目录。
    ///
    /// 两类：① 升级留下的旧模型（pendingRepos）；② 孤儿目录——目录里已经没有、又没被选中的
    /// 仓库（模型换代后被下架的那些）。
    /// **selectedRepo 永远不删**，哪怕它同时出现在 pendingRepos 里（那只能是状态写坏了）。
    /// 返回顺序与 existingRepos 一致、去重，方便日志逐条对照。
    static func directoriesToRemove(existingRepos: [String],
                                    selectedRepo: String,
                                    catalogRepos: [String],
                                    pendingRepos: [String]) -> [String] {
        let selected = selectedRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = Set(pendingRepos)
        let listed = Set(catalogRepos)
        var seen = Set<String>()
        var result: [String] = []
        for repo in existingRepos {
            guard repo != selected, !seen.contains(repo) else { continue }
            if pending.contains(repo) || !listed.contains(repo) {
                seen.insert(repo)
                result.append(repo)
            }
        }
        return result
    }

    /// 清单里有哪些文件在本地缺了 / 大小不对。
    /// localSizes 由调用方从磁盘读好（纯函数才能单测）。size <= 0 的清单项（HF 偶尔不给大小）
    /// 只要求文件存在，不比大小——宁可少验一项，也不要因为服务端少给一个字段就判定下载失败。
    static func mismatchedFiles(manifest: [QwenModelDownloader.ManifestFile],
                                localSizes: [String: Int64]) -> [String] {
        manifest.compactMap { file in
            guard let local = localSizes[file.path] else { return file.path }
            if file.size > 0 && local != file.size { return file.path }
            return nil
        }
    }

    /// 校验用的合成音频：1 秒 16 kHz 的低幅正弦。
    ///
    /// 为什么不用静音：mlx-swift-asr 对过短/空输入会直接返回空文本（<400 sample 那条路），
    /// 那样「跑通」就证明不了解码器真的跑过。低幅正弦保证走完整条链路，又不会被当成人声内容。
    /// 纯函数，可单测（长度、幅度都钉死）。
    static func probeSamples(seconds: Double = 1.0, sampleRate: Int = 16_000) -> [Float] {
        let count = max(1, Int(seconds * Double(sampleRate)))
        let step = 2 * Float.pi * 220 / Float(sampleRate)   // 220 Hz
        return (0..<count).map { 0.05 * sin(step * Float($0)) }
    }
}

// MARK: - 升级流程

final class ModelUpgrader: ObservableObject {

    static let shared = ModelUpgrader()

    enum Phase: Equatable {
        case idle
        case downloading
        case verifying
        case done
        case failed
    }

    /// 当前该提示什么（界面据此决定横幅长什么样）
    @Published private(set) var decision: ModelUpgradeDecision = .none
    @Published private(set) var phase: Phase = .idle
    /// 一次性状态文字。**是语言快照**：切界面语言时由界面调 clearStatus()（3.1.1 的坑）
    @Published private(set) var statusText = ""
    @Published private(set) var isChecking = false

    private let d = UserDefaults.standard
    private var downloadObserver: AnyCancellable?
    /// 正在走升级流程的目标仓库（nil = 没有）。用它区分「我们发起的下载」和用户在设置里手点的下载
    private var inFlightRepo: String?
    private var isRefreshFlow = false

    private init() {}

    // MARK: 提示

    /// 重新判定一次。allowRevisionCheck = 是否允许为「同仓库新修订」去问一次 HF
    /// （启动路径只在 24 小时到点时给 true，设置页的手动按钮永远 true）。
    func refreshDecision(allowRevisionCheck: Bool, completion: (() -> Void)? = nil) {
        let repo = Settings.shared.qwenModelRepo
        let catalog = ModelCatalogStore.shared.models
        let language = Settings.shared.recognitionLanguage
        let dismissed = dismissedRepo

        let local = ModelUpgradeLogic.decide(installedRepo: repo,
                                            catalog: catalog,
                                            appVersion: UpdateChecker.currentVersion,
                                            languageCode: language,
                                            revisionUpdateAvailable: false,
                                            dismissedRepo: dismissed)
        if local != .none || !allowRevisionCheck {
            apply(local)
            completion?()
            return
        }
        // 目录里没有更好的了，才去问 HF「已装的这个仓库有没有新修订」
        QwenModelDownloader.checkForUpdate(repo: repo) { [weak self] hasUpdate, _ in
            guard let self = self else { return }
            let decision = ModelUpgradeLogic.decide(installedRepo: repo,
                                                    catalog: catalog,
                                                    appVersion: UpdateChecker.currentVersion,
                                                    languageCode: language,
                                                    revisionUpdateAvailable: hasUpdate,
                                                    dismissedRepo: dismissed)
            self.apply(decision)
            completion?()
        }
    }

    /// 启动路径：目录最多 24 小时查一次；查了才顺带问 HF 修订。
    func refreshDecisionAtLaunch() {
        ModelCatalogStore.shared.checkAtLaunchIfDue { [weak self] didFetch in
            self?.refreshDecision(allowRevisionCheck: didFetch)
        }
    }

    /// 设置页「检查模型更新」按钮：强制拉一次目录 + 问一次修订，并给一句人能读的结论。
    func checkNow(completion: @escaping (String) -> Void) {
        // 已经在查了也要回话：界面那个按钮正卡在「检查中…」，不回调它就永远转不回来
        guard !isChecking else {
            completion(tr("正在检查，请稍候…", "Already checking, one moment…"))
            return
        }
        isChecking = true
        ModelCatalogStore.shared.refresh { [weak self] _ in
            guard let self = self else { return }
            self.refreshDecision(allowRevisionCheck: true) {
                self.isChecking = false
                completion(self.checkResultMessage())
            }
        }
    }

    private func checkResultMessage() -> String {
        switch decision {
        case .none:
            return tr("已是最新：没有比当前更合适的识别模型",
                      "Up to date - no better speech model is available")
        case .upgrade(let repo):
            let name = displayName(for: repo)
            return tr("发现更好的识别模型：", "A better speech model is available: ") + name
        case .refresh:
            return tr("当前模型在仓库里有新修订，可以重新下载更新",
                      "The current model has a newer revision in the repo - re-download to update")
        case .needsAppUpdate(_, let min):
            return tr("有新模型，但需要 MicType \(min) 或更高版本",
                      "A new model exists but needs MicType \(min) or newer")
        }
    }

    private func apply(_ new: ModelUpgradeDecision) {
        guard decision != new else { return }
        decision = new
        switch new {
        case .none:
            Log.info("Model upgrade: nothing to offer")
        case .upgrade(let repo):
            Log.info("Model upgrade available repo=\(repo)")
        case .refresh(let repo):
            Log.info("Model revision update available repo=\(repo)")
        case .needsAppUpdate(let repo, let min):
            Log.info("Model upgrade blocked repo=\(repo) needsApp=\(min) current=\(UpdateChecker.currentVersion)")
        }
    }

    /// 「以后再说」：只压住这一个仓库的提示，菜单栏入口和设置页按钮都还在
    func dismissCurrentOffer() {
        switch decision {
        case .upgrade(let repo), .needsAppUpdate(let repo, _):
            d.set(repo, forKey: SettingsKeys.dismissedModelUpgradeRepo)
            Log.info("Model upgrade offer dismissed repo=\(repo)")
        case .refresh, .none:
            break
        }
        apply(.none)
    }

    private var dismissedRepo: String? {
        let v = d.string(forKey: SettingsKeys.dismissedModelUpgradeRepo) ?? ""
        return v.isEmpty ? nil : v
    }

    /// 目录里这个仓库叫什么（目录里没有就把仓库 ID 原样显示——不编名字）
    func displayName(for repo: String) -> String {
        ModelCatalogStore.shared.catalog.model(repo: repo)?.displayName.localized ?? repo
    }

    /// 目标模型的体量说明（界面上要把「这次要下多少」说在按钮上）
    func sizeNote(for repo: String) -> String {
        guard let model = ModelCatalogStore.shared.catalog.model(repo: repo) else { return "" }
        return QwenModels.sizeNote(bytes: model.sizeBytes)
    }

    /// 目标模型的语言能力说明
    func languagesNote(for repo: String) -> String {
        ModelCatalogStore.shared.catalog.model(repo: repo)?.languagesNote.localized ?? ""
    }

    // MARK: 一键升级

    /// 目标仓库（没有可升级的就是 nil）
    var targetRepo: String? {
        switch decision {
        case .upgrade(let repo), .refresh(let repo): return repo
        case .needsAppUpdate, .none: return nil
        }
    }

    var isBusy: Bool { phase == .downloading || phase == .verifying }

    /// 一键：下载 → 校验 → 切换。全程非模态，失败回滚。
    func startUpgrade() {
        guard let repo = targetRepo, !isBusy else { return }
        guard !QwenModelDownloader.shared.isDownloading else {
            statusText = tr("已有下载在进行中，请先等它结束",
                            "A download is already running - let it finish first")
            return
        }
        isRefreshFlow = (decision == .refresh(repo: repo))
        inFlightRepo = repo
        phase = .downloading
        statusText = tr("正在下载 ", "Downloading ") + displayName(for: repo)
        Log.info("Model upgrade start repo=\(repo) refresh=\(isRefreshFlow) "
                 + "from=\(Settings.shared.qwenModelRepo)")

        // 新模型下到它自己的目录（和当前模型平级）。正在用的那份一个字节都不动——
        // 校验之前用户随时可以照常听写，Esc 也照常。
        // 只有「同仓库新修订」这一种必须原地覆盖（force），那是用户明确要更新这一份。
        QwenModelDownloader.shared.download(repo: repo, force: isRefreshFlow)
        observeDownload(repo: repo)
    }

    private func observeDownload(repo: String) {
        downloadObserver = QwenModelDownloader.shared.$isDownloading
            .dropFirst()
            .sink { [weak self] downloading in
                guard let self = self, !downloading, self.inFlightRepo == repo else { return }
                self.downloadObserver = nil
                let dir = QwenModels.localDirectory(for: repo)
                guard FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("model.safetensors").path) else {
                    self.fail(tr("下载没有完成（已下好的文件保留，可以再点一次继续）",
                                 "The download did not finish - files already fetched are kept, click again to resume"))
                    return
                }
                self.verify(repo: repo)
            }
    }

    // MARK: 校验

    /// 三道验证，从便宜到贵：清单齐全且大小一致 → config.json 能解析 → 真跑一遍 1 秒识别。
    private func verify(repo: String) {
        phase = .verifying
        statusText = tr("正在校验新模型…", "Verifying the new model…")
        Log.info("Model verify start repo=\(repo) bytes=\(QwenModels.directorySize(repo: repo))")

        QwenModelDownloader.fetchManifest(repo: repo) { [weak self] manifest in
            guard let self = self, self.inFlightRepo == repo else { return }
            let dir = QwenModels.localDirectory(for: repo)
            let fm = FileManager.default

            if let manifest = manifest {
                var localSizes: [String: Int64] = [:]
                for file in manifest {
                    let path = dir.appendingPathComponent(file.path).path
                    if let attrs = try? fm.attributesOfItem(atPath: path),
                       let size = attrs[.size] as? Int64 {
                        localSizes[file.path] = size
                    }
                }
                let bad = ModelUpgradeLogic.mismatchedFiles(manifest: manifest, localSizes: localSizes)
                guard bad.isEmpty else {
                    Log.warn("Model verify files mismatched repo=\(repo) count=\(bad.count) first=\(bad[0])")
                    self.fail(tr("新模型文件不完整（\(bad.count) 个文件对不上），已保留当前模型",
                                 "The new model is incomplete (\(bad.count) files do not match) - your current model is unchanged"))
                    return
                }
                Log.info("Model verify files ok repo=\(repo) files=\(manifest.count)")
            } else {
                // 清单拿不到（离网 / 镜像挂了）就退一步只查关键文件：宁可少验一项，
                // 也不要因为查不了清单就把一次成功的下载判成失败。后面那一遍真识别仍然要跑。
                Log.warn("Model verify manifest unavailable repo=\(repo), falling back to key files")
                for name in ["model.safetensors", "config.json"] {
                    guard fm.fileExists(atPath: dir.appendingPathComponent(name).path) else {
                        self.fail(tr("新模型缺少 \(name)，已保留当前模型",
                                     "The new model is missing \(name) - your current model is unchanged"))
                        return
                    }
                }
            }

            // config.json 能不能解析：坏 JSON 在加载时是一句看不懂的报错，先在这里挡掉
            let configURL = dir.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: configURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  !json.isEmpty else {
                self.fail(tr("新模型的 config.json 无法解析，已保留当前模型",
                             "The new model's config.json could not be parsed - your current model is unchanged"))
                return
            }

            // 最后一关：真跑一遍。通过了才敢切设置、才敢排队删旧模型。
            QwenEngine.shared.verifyModel(directory: dir,
                                          samples: ModelUpgradeLogic.probeSamples()) { error in
                guard self.inFlightRepo == repo else { return }
                if let error = error {
                    self.fail(error.message)
                } else {
                    self.switchTo(repo: repo)
                }
            }
        }
    }

    // MARK: 切换与回滚

    private func switchTo(repo: String) {
        let old = Settings.shared.qwenModelRepo
        inFlightRepo = nil
        if old == repo {
            // 同仓库新修订：设置不用动，只把内存里的旧权重放掉，下一次听写自然加载新文件
            QwenEngine.shared.unloadModel()
            QwenEngine.shared.preload()
            phase = .done
            statusText = tr("模型已更新到最新修订 ✓", "Model updated to the latest revision ✓")
            Log.info("Model refresh complete repo=\(repo)")
            apply(.none)
            return
        }
        // 切换本身就是一次写入：先卸掉旧模型，再改设置，再预热新的。
        // 旧目录**不删**——进 pendingCleanup，等新模型真实听写成功过一次。
        QwenEngine.shared.unloadModel()
        Settings.shared.qwenModelRepo = repo
        addPendingCleanup(old)
        QwenEngine.shared.preload()
        phase = .done
        statusText = tr("已切换到 ", "Now using ") + displayName(for: repo)
            + tr("，旧模型会在下一次成功听写后自动清理",
                 " - the old model is removed automatically after your next successful dictation")
        Log.info("Model switch complete repo=\(repo) old=\(old) pendingCleanup=\(pendingCleanup.count)")
        apply(.none)
    }

    private func fail(_ message: String) {
        inFlightRepo = nil
        downloadObserver = nil
        phase = .failed
        statusText = message
        Log.warn("Model upgrade failed: " + String(message.prefix(160)))
    }

    /// 语言切换时界面调一下：一次性状态文字是快照，留着就会中英混搭
    func clearStatus() {
        statusText = ""
        if phase == .done || phase == .failed { phase = .idle }
    }

    // MARK: 清理

    private var pendingCleanup: [String] {
        get { d.stringArray(forKey: SettingsKeys.pendingModelCleanup) ?? [] }
        set { d.set(newValue, forKey: SettingsKeys.pendingModelCleanup) }
    }

    private func addPendingCleanup(_ repo: String) {
        let repo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty, repo != Settings.shared.qwenModelRepo else { return }
        var list = pendingCleanup
        guard !list.contains(repo) else { return }
        list.append(repo)
        pendingCleanup = list
    }

    /// 新模型在真实听写里成功出字过一次 → 现在可以删旧的了。
    /// 由 QwenEngine 的成功路径调用（主线程）。没有待清理项时什么都不做，开销为零。
    func noteSuccessfulTranscription() {
        guard !pendingCleanup.isEmpty else { return }
        runCleanup()
    }

    /// 删掉待清理的旧模型，顺带删掉「目录里已经没有、又没被选中」的孤儿目录。
    ///
    /// 孤儿清理**只跟在一次升级之后**做，不在启动时自己动手：删几百 MB 是不可逆的，
    /// 用户刚点过一次升级是唯一能说明「他确实想换代」的时机。
    private func runCleanup() {
        let selected = Settings.shared.qwenModelRepo
        let existing = QwenModels.repoDirectories()
        let catalogRepos = ModelCatalogStore.shared.models.map { $0.repo }
        let victims = ModelUpgradeLogic.directoriesToRemove(existingRepos: existing,
                                                           selectedRepo: selected,
                                                           catalogRepos: catalogRepos,
                                                           pendingRepos: pendingCleanup)
        pendingCleanup = []
        guard !victims.isEmpty else {
            Log.info("Model cleanup: nothing to remove selected=\(selected)")
            return
        }
        // 删几百 MB 会卡住主线程（还可能触发 Spotlight），挪到后台；日志只记仓库 ID 与字节数
        DispatchQueue.global(qos: .utility).async {
            for repo in victims {
                let bytes = QwenModels.directorySize(repo: repo)
                let dir = QwenModels.localDirectory(for: repo)
                do {
                    try FileManager.default.removeItem(at: dir)
                    Log.info("Model cleanup removed repo=\(repo) bytes=\(bytes)")
                } catch {
                    // 删不掉不是错误路径的一部分（磁盘权限、文件被占用），下次升级会再试
                    Log.warn("Model cleanup failed repo=\(repo): "
                             + String(error.localizedDescription.prefix(80)))
                }
            }
        }
    }
}
