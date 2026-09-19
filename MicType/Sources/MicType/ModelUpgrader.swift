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
//   3. **清理**（删旧模型）——要同时满足：新模型**真实听写成功过一次**，且换模型之后
//      **至少完整重启过一次**。
//
// 为什么第 3 步要等这两件事：旧模型是用户唯一的退路。下载完整、能加载，都不等于在他的机器上、
// 他的麦克风上真的出字；而一次成功的听写也只证明"这一刻它能跑"——权重冷加载、Metal 管线重建
// 这些只有重启之后才会重走一遍。两个条件都过了再删，最坏情况只是多占一天磁盘；反过来最坏情况
// 是他明天开会前发现听写坏了、而旧模型已经被我们删了。
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
    ///   • 用户为某语言专门选了一档（目录里给那一档标了 recommendedFor），就**不再**拿通用
    ///     推荐档去劝他换回来——那是替用户做主。当前目录里没有任何语言专用档（见 CatalogModel）；
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
    /// 三类：① 升级留下的旧模型（pendingRepos）；② 只下了一半、没被选中的目录
    /// （incompleteRepos——带 `.incomplete` 标记的那些，按定义加载不了，只是在占几百 MB）；
    /// ③ 孤儿目录——目录里已经没有、又没被选中的仓库（模型换代后被下架的那些）。
    /// **selectedRepo 永远不删**，哪怕它同时出现在 pendingRepos 里（那只能是状态写坏了）。
    ///
    /// `pruneOrphans` = 这一轮能不能信任 catalogRepos。目录退化成缓存 / 内置那份时它是 false：
    /// 一份过时的目录会把用户特意下载、只是没选中的那一档判成"孤儿"，几百 MB 无声删掉——
    /// 宁可多占一天磁盘，也不删一份用户主动要的模型。
    /// 返回顺序与 existingRepos 一致、去重，方便日志逐条对照。
    static func directoriesToRemove(existingRepos: [String],
                                    selectedRepo: String,
                                    catalogRepos: [String],
                                    pendingRepos: [String],
                                    incompleteRepos: [String] = [],
                                    pruneOrphans: Bool = true) -> [String] {
        let selected = selectedRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = Set(pendingRepos)
        let listed = Set(catalogRepos)
        let halfDone = Set(incompleteRepos)
        var seen = Set<String>()
        var result: [String] = []
        for repo in existingRepos {
            guard repo != selected, !seen.contains(repo) else { continue }
            let isOrphan = pruneOrphans && !listed.contains(repo)
            if pending.contains(repo) || halfDone.contains(repo) || isOrphan {
                seen.insert(repo)
                result.append(repo)
            }
        }
        return result
    }

    /// 「同仓库有新修订」这条提示要不要摆出来。
    ///
    /// 用户点过「以后再说」之后就别再摆——但压的是**那一次的那份文件**（清单指纹），
    /// 不是这个仓库：上游真出了下一版，指纹变了，提示照样该回来。
    /// 拿不到指纹（旧路径 / 网络只给了半截）时按"没压过"处理：宁可多问一次，
    /// 也不要把一次真的更新永久藏起来。
    static func shouldOfferRefresh(hasUpdate: Bool,
                                   remoteFingerprint: String?,
                                   dismissedFingerprint: String?) -> Bool {
        guard hasUpdate else { return false }
        guard let remote = remoteFingerprint, !remote.isEmpty,
              let dismissed = dismissedFingerprint, !dismissed.isEmpty else { return true }
        return remote != dismissed
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

    /// 能不能删旧模型了。**两个条件都要满足**，顺序不限：
    ///   ① 新模型在真实听写里成功出过一次字（succeeded）；
    ///   ② 换模型之后 App 至少完整重启过一次（currentLaunch > switchLaunch）。
    ///
    /// 为什么非要加第二条：一次成功的听写只证明"这一刻它能跑"。真正会咬人的是冷启动——
    /// 权重从磁盘加载、Metal 管线重建、内存不够时的那条路，全都只在重新启动之后才走一遍。
    /// 旧模型是用户唯一的退路，多留一天几百 MB，换的是"明天开会前它起不来"时还有东西可退。
    /// switchLaunch <= 0（老版本升上来、状态丢了）按"没记录"处理：宁可再等一次重启，也不冒险删。
    static func mayCleanup(switchLaunch: Int, currentLaunch: Int, succeeded: Bool) -> Bool {
        guard succeeded else { return false }
        guard switchLaunch > 0 else { return false }
        return currentLaunch > switchLaunch
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
    /// 正在往暂存目录下的那个仓库（nil = 这一轮不走暂存）。同仓库重下一律走暂存：
    /// 正在用的那份模型在校验通过之前一个字节都不动。
    private var stagingRepo: String?
    /// 最近一次「有没有新修订」检查看到的远端清单指纹。「以后再说」压的就是这一个值。
    private var latestRefreshFingerprint: String?
    /// 这一轮校验用的远端清单。切换成功之后用它写更新基线。
    private var verifiedManifest: [QwenModelDownloader.ManifestFile]?
    /// 校验通过、但听写还没结束时，每隔一秒再看一眼；最多等这么多次（15 分钟）。
    /// 录音上限是 600 秒，再加上润色/插入，15 分钟足够走完一轮还有余量。
    private static let maxSwitchWaitTicks = 900

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
        // 目录里没有更好的了，才去问 HF「已装的这个仓库的文件有没有变」
        QwenModelDownloader.checkForUpdate(repo: repo) { [weak self] hasUpdate, _, fingerprint in
            guard let self = self else { return }
            self.latestRefreshFingerprint = fingerprint
            let offer = ModelUpgradeLogic.shouldOfferRefresh(
                hasUpdate: hasUpdate,
                remoteFingerprint: fingerprint,
                dismissedFingerprint: self.dismissedRefreshFingerprint(repo: repo))
            let decision = ModelUpgradeLogic.decide(installedRepo: repo,
                                                    catalog: catalog,
                                                    appVersion: UpdateChecker.currentVersion,
                                                    languageCode: language,
                                                    revisionUpdateAvailable: offer,
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
        case .refresh(let repo):
            // 修订提示压的是**这一份文件**（清单指纹），不是这个仓库：
            // 上游真出下一版时指纹会变，提示照样回来。指纹这次没拿到就只压本次会话。
            if let fingerprint = latestRefreshFingerprint, !fingerprint.isEmpty {
                d.set(fingerprint, forKey: SettingsKeys.dismissedModelRefreshFingerprint(repo))
                Log.info("Model refresh offer dismissed repo=\(repo) fp=\(fingerprint)")
            } else {
                Log.info("Model refresh offer dismissed for this session repo=\(repo) (no fingerprint)")
            }
        case .none:
            break
        }
        apply(.none)
    }

    private var dismissedRepo: String? {
        let v = d.string(forKey: SettingsKeys.dismissedModelUpgradeRepo) ?? ""
        return v.isEmpty ? nil : v
    }

    private func dismissedRefreshFingerprint(repo: String) -> String? {
        let v = d.string(forKey: SettingsKeys.dismissedModelRefreshFingerprint(repo)) ?? ""
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
        // 听写正在进行时不开这一路：切换会卸掉正在用的权重、改写设置，
        // 在飞的那一轮就会前半段旧模型、后半段新模型（语言锁还是旧模型检测出来的）。
        // 同一条判据麦克风自检早就在用（AppDelegate.isDictationBusy）。
        guard !AppDelegate.isDictationBusy else {
            statusText = tr("正在听写，先说完这一轮再升级",
                            "A dictation is in progress - finish it before upgrading")
            return
        }
        isRefreshFlow = (decision == .refresh(repo: repo))
        stagingRepo = isRefreshFlow ? repo : nil
        inFlightRepo = repo
        phase = .downloading
        statusText = tr("正在下载 ", "Downloading ") + displayName(for: repo)
        Log.info("Model upgrade start repo=\(repo) refresh=\(isRefreshFlow) "
                 + "from=\(Settings.shared.qwenModelRepo)")

        // 换仓库：新模型下到它自己的目录（和当前模型平级）。
        // 同仓库重下：下到**暂存目录**——那个仓库的正式目录正是用户此刻在用的那一份，
        // 原地重下等于先把他的模型删了再祈祷网络不断。两条路都一样：
        // 校验之前正在用的那份一个字节都不动，用户随时可以照常听写。
        QwenModelDownloader.shared.download(repo: repo, force: isRefreshFlow, staging: isRefreshFlow)
        observeDownload(repo: repo)
    }

    /// 这一轮的新文件落在哪个目录（同仓库重下 = 暂存目录）
    private func downloadDirectory(for repo: String) -> URL {
        stagingRepo == repo ? QwenModels.stagingDirectory(for: repo)
                            : QwenModels.localDirectory(for: repo)
    }

    private func observeDownload(repo: String) {
        downloadObserver = QwenModelDownloader.shared.$isDownloading
            .dropFirst()
            .sink { [weak self] downloading in
                guard let self = self, !downloading, self.inFlightRepo == repo else { return }
                self.downloadObserver = nil
                // 「下完了」= 权重在 + 下载器已经把 .incomplete 标记删掉（QwenModels.isFullyDownloaded）
                guard QwenModels.isFullyDownloaded(at: self.downloadDirectory(for: repo)) else {
                    if self.stagingRepo == repo {
                        self.fail(tr("下载没有完成，当前模型没有任何改动（可以再点一次重试）",
                                     "The download did not finish - your current model is untouched, click again to retry"))
                    } else {
                        self.fail(tr("下载没有完成（已下好的文件保留，可以再点一次继续）",
                                     "The download did not finish - files already fetched are kept, click again to resume"))
                    }
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
        let dir = downloadDirectory(for: repo)
        Log.info("Model verify start repo=\(repo) bytes=\(QwenModels.directorySize(at: dir))")

        QwenModelDownloader.fetchManifest(repo: repo) { [weak self] manifest in
            guard let self = self, self.inFlightRepo == repo else { return }
            let fm = FileManager.default
            // 校验用的这份清单就是「这一份文件长什么样」的权威记录：切换成功之后拿它
            // 写更新基线（下载当时不写——没校验过的一份不配当基线，见 recordManifestBaseline）
            self.verifiedManifest = manifest

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
                    self.switchWhenIdle(repo: repo)
                }
            }
        }
    }

    // MARK: 切换与回滚

    /// 听写还在进行时**不切模型**：一轮在飞的听写正拿着旧权重解码，这时候卸模型 + 改设置
    /// 会让同一次交付里前半段是旧模型、后半段是新模型，语言锁还是旧模型检测出来的那个。
    /// 校验已经过了，等一下不花任何代价——每秒看一眼，回到空闲就切。
    private func switchWhenIdle(repo: String, attempt: Int = 0) {
        guard AppDelegate.isDictationBusy else {
            switchTo(repo: repo)
            return
        }
        guard attempt < Self.maxSwitchWaitTicks else {
            fail(tr("听写一直没有结束，这次升级先停下（当前模型没有改动，稍后再点一次即可）",
                    "The dictation never finished, so the upgrade stopped - your current model is unchanged, try again later"))
            return
        }
        if attempt == 0 {
            statusText = tr("新模型已校验通过，等这一轮听写结束后切换…",
                            "The new model is verified - switching once this dictation finishes…")
            Log.info("Model switch deferred (dictation busy) repo=\(repo)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, self.inFlightRepo == repo else { return }
            self.switchWhenIdle(repo: repo, attempt: attempt + 1)
        }
    }

    /// 暂存目录里那份校验过的模型换进正式目录。同卷改名，要么整份换成功、要么原样不动。
    private func promoteStaging(repo: String) -> Bool {
        let staging = QwenModels.stagingDirectory(for: repo)
        let live = QwenModels.localDirectory(for: repo)
        let fm = FileManager.default
        guard fm.fileExists(atPath: staging.path) else { return false }
        do {
            if fm.fileExists(atPath: live.path) {
                _ = try fm.replaceItemAt(live, withItemAt: staging)
            } else {
                try fm.createDirectory(at: live.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: staging, to: live)
            }
            stagingRepo = nil
            return true
        } catch {
            Log.warn("Model staging promote failed repo=\(repo): "
                     + String(error.localizedDescription.prefix(120)))
            return false
        }
    }

    /// 这一轮下下来的文件已经就位：把清单指纹记成新的更新基线。
    /// **在这一刻记**，不在下载完成时记——没校验过、没换进去的一份不配当基线，
    /// 提前记下会让一次失败的更新被当成"已经装上了"，真正的新修订从此被藏起来。
    private func recordVerifiedBaseline(repo: String) {
        guard let manifest = verifiedManifest, !manifest.isEmpty else { return }
        QwenModelDownloader.recordManifestBaseline(repo: repo, manifest: manifest)
        verifiedManifest = nil
    }

    private func switchTo(repo: String) {
        let old = Settings.shared.qwenModelRepo
        inFlightRepo = nil
        if old == repo {
            // 同仓库新修订：文件在暂存目录里等着。先放掉内存里的旧权重（目录要被换掉），
            // 再原子换进去；换不进去就当没发生——用户那份模型还在原地，一个字节没动。
            QwenEngine.shared.unloadModel()
            guard promoteStaging(repo: repo) else {
                fail(tr("新模型没能换进模型目录（磁盘写入失败），当前模型没有改动",
                        "The verified copy could not be moved into place - your current model is unchanged"))
                QwenEngine.shared.preload()
                return
            }
            recordVerifiedBaseline(repo: repo)
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
        recordVerifiedBaseline(repo: repo)
        QwenEngine.shared.preload()
        phase = .done
        statusText = tr("已切换到 ", "Now using ") + displayName(for: repo)
            + tr("，旧模型会在下一次成功听写并重启之后自动清理",
                 " - the old model is removed automatically after your next successful dictation and a restart")
        Log.info("Model switch complete repo=\(repo) old=\(old) pendingCleanup=\(pendingCleanup.count)")
        apply(.none)
    }

    private func fail(_ message: String) {
        inFlightRepo = nil
        downloadObserver = nil
        verifiedManifest = nil
        // 暂存目录里那半份（或没通过校验的那一份）留着只会白占几百 MB，而且下一次重试
        // 本来就是整份重下（force）。用户在用的那份模型不在这里，删它没有任何风险。
        if let staging = stagingRepo {
            try? FileManager.default.removeItem(at: QwenModels.stagingDirectory(for: staging))
            stagingRepo = nil
        }
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

    /// 换模型发生在第几次启动（0 = 没有待清理的换代）
    private var switchLaunch: Int {
        get { d.integer(forKey: SettingsKeys.pendingCleanupLaunch) }
        set { d.set(newValue, forKey: SettingsKeys.pendingCleanupLaunch) }
    }

    /// 新模型真实听写成功过没有（跨重启保留，所以是 UserDefaults 而不是内存标志）
    private var cleanupSucceeded: Bool {
        get { d.bool(forKey: SettingsKeys.pendingCleanupSucceeded) }
        set { d.set(newValue, forKey: SettingsKeys.pendingCleanupSucceeded) }
    }

    /// 本次是第几次启动。AppDelegate 启动时调一次 noteAppLaunch() 把它 +1。
    var launchCount: Int { d.integer(forKey: SettingsKeys.appLaunchCount) }

    /// App 启动时调一次：启动计数 +1，然后看看上一次换的模型现在够不够条件删旧的。
    /// 「至少重启过一次」这条门槛就是靠这个计数实现的（见 ModelUpgradeLogic.mayCleanup）。
    func noteAppLaunch() {
        d.set(launchCount + 1, forKey: SettingsKeys.appLaunchCount)
        purgeStagingLeftovers()
        cleanupIfAllowed()
    }

    /// 上一次重下下到一半就退出 App 的话，暂存目录会留着几百 MB。
    /// 启动这一刻不可能有下载在跑，整个 `.staging` 直接清掉：重试本来就是整份重下。
    private func purgeStagingLeftovers() {
        let dir = Paths.modelsDir.appendingPathComponent(".staging", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let bytes = QwenModels.directorySize(at: dir)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: dir)
            Log.info("Model staging leftovers removed bytes=\(bytes)")
        }
    }

    private func addPendingCleanup(_ repo: String) {
        let repo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty, repo != Settings.shared.qwenModelRepo else { return }
        // 这一轮换代的两个前提从头记：发生在第几次启动、还没有成功听写过
        switchLaunch = max(1, launchCount)
        cleanupSucceeded = false
        var list = pendingCleanup
        guard !list.contains(repo) else { return }
        list.append(repo)
        pendingCleanup = list
    }

    /// 新模型在真实听写里成功出字过一次。由 QwenEngine 的成功路径调用（主线程），
    /// `repo` = **产出这段文字的那份权重**所在的仓库。
    ///
    /// 为什么非要带着仓库来：一轮在切换之前就开始、拿着旧权重解码到一半的听写，会在切换
    /// **之后**才出字。不认来源的话，旧模型的这一次成功就把"新模型跑通过"那道闸打开了，
    /// 下次启动删掉的正是它自己——而用户唯一的退路就是它。
    /// **记下来不等于立刻删**：还要等至少一次重启（见 ModelUpgradeLogic.mayCleanup）。
    /// 没有待清理项时什么都不做，开销为零。
    func noteSuccessfulTranscription(repo: String) {
        guard !pendingCleanup.isEmpty else { return }
        let used = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !used.isEmpty, used == Settings.shared.qwenModelRepo,
              !pendingCleanup.contains(used) else {
            Log.info("Model cleanup gate ignored a transcription from repo=\(used)")
            return
        }
        if !cleanupSucceeded { cleanupSucceeded = true }
        cleanupIfAllowed()
    }

    /// 两个条件都满足了才真删。够不着就安静留着，下一次启动 / 下一次成功听写会再问一遍。
    private func cleanupIfAllowed() {
        guard !pendingCleanup.isEmpty else { return }
        guard ModelUpgradeLogic.mayCleanup(switchLaunch: switchLaunch,
                                           currentLaunch: launchCount,
                                           succeeded: cleanupSucceeded) else {
            Log.info("Model cleanup deferred switchLaunch=\(switchLaunch) launch=\(launchCount)"
                     + " succeeded=\(cleanupSucceeded) pending=\(pendingCleanup.count)")
            return
        }
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
        // 孤儿只在「这一轮真的从远端取到过目录」时才扫：启动时 noteAppLaunch() 排在目录刷新
        // 之前，缓存丢了的那次启动读到的是内置那两条——拿一份退化的目录去判孤儿，会把用户
        // 特意下载、只是没选中的那一档几百 MB 无声删掉。
        let catalogIsLive = ModelCatalogStore.shared.isFromRemote
        // 半份下载（带 .incomplete）按定义加载不了，只是在占磁盘，顺手回收；
        // 但正在下的那一份不能碰——下载器还在往里写。
        let incomplete = QwenModelDownloader.shared.isDownloading
            ? []
            : existing.filter { QwenModels.hasIncompleteMarker(repo: $0) }
        let victims = ModelUpgradeLogic.directoriesToRemove(existingRepos: existing,
                                                           selectedRepo: selected,
                                                           catalogRepos: catalogRepos,
                                                           pendingRepos: pendingCleanup,
                                                           incompleteRepos: incomplete,
                                                           pruneOrphans: catalogIsLive)
        pendingCleanup = []
        switchLaunch = 0
        cleanupSucceeded = false
        guard !victims.isEmpty else {
            Log.info("Model cleanup: nothing to remove selected=\(selected) catalogLive=\(catalogIsLive)")
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
