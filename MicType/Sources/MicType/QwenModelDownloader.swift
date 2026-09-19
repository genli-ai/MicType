import Foundation
import Combine

/// 下载失败的原因（语言中性）。为什么不直接存一句中文/英文：见 `QwenDownloadPhase`。
enum QwenDownloadFailure: Equatable {
    case fileListUnavailable
    case emptyRepo
    /// 系统层面的写盘失败；detail 是 OS 给的原文（语言由系统决定），只当次要细节附在后面
    case saveFailed(detail: String)
    case allMirrorsFailed

    var text: String {
        switch self {
        case .fileListUnavailable:
            return tr("无法获取模型文件清单，请检查网络", "Could not fetch the model file list — check your network")
        case .emptyRepo:
            return tr("模型仓库为空或清单格式异常", "Model repo is empty or the manifest is malformed")
        case .saveFailed(let detail):
            return tr("保存失败：", "Save failed: ") + detail
        case .allMirrorsFailed:
            return tr("下载源均失败，请检查网络后重试（已完成的文件会保留，重试可续传）",
                      "All mirrors failed — check your network and retry (completed files are kept; retry resumes)")
        }
    }
}

/// 下载进行到哪一步——**语言中性**：只存事实（阶段 + 计数 + 字节数），不存拼好的文字。
/// 为什么：以前下载器直接存一句 `statusText`，那是一次性生成的语言快照，切界面语言不会
/// 自己刷新（CLAUDE.md「i18n 快照字符串」那个老坑），而下载正在进行时又不能一清了之
/// ——于是英文界面下能一直挂着一句中文。现在文字由 `statusText` 现场 tr() 渲染：
/// 视图每次重绘都重新渲染，切语言立刻跟上，下载中也不例外。
enum QwenDownloadPhase: Equatable {
    case idle
    case fetchingList
    /// 刚起一个文件、还没有字节数（此时报文件路径比报 0 MB 有用）
    case startingFile(fileIndex: Int, fileCount: Int, file: String)
    case downloading(fileIndex: Int, fileCount: Int, doneBytes: Int64, totalBytes: Int64)
    case completed(fileCount: Int)
    case cancelled
    case failed(QwenDownloadFailure)

    static func megabytes(_ bytes: Int64) -> Double {
        Double(bytes) / 1_048_576
    }

    /// 界面上那一行状态文字。**每次读都重新渲染**，所以它永远跟着当前界面语言
    var statusText: String {
        switch self {
        case .idle:
            return ""
        case .fetchingList:
            return tr("正在获取文件清单…", "Fetching file list…")
        case .startingFile(let index, let count, let file):
            return tr("下载中 ", "Downloading ") + "(\(index + 1)/\(count)): \(file)"
        case .downloading(let index, let count, let done, let total):
            return String(format: tr("下载中 (%d/%d) %.0f / %.0f MB", "Downloading (%d/%d) %.0f / %.0f MB"),
                          index + 1, count, Self.megabytes(done), Self.megabytes(total))
        case .completed(let count):
            return tr("下载完成 ✓（", "Download complete ✓ (") + "\(count)" + tr(" 个文件）", " files)")
        case .cancelled:
            return tr("已取消", "Cancelled")
        case .failed(let failure):
            return tr("失败：", "Failed: ") + failure.text
        }
    }
}

/// Qwen 模型下载器：HF 仓库是多文件目录（safetensors/config/tokenizer…），
/// 先取文件清单再逐个下载。hf-mirror.com 优先，失败回退 huggingface.co。
final class QwenModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {

    static let shared = QwenModelDownloader()

    @Published var isDownloading = false
    @Published var progress: Double = 0
    /// 只存阶段，不存文字——界面用下面的 `statusText` 现场渲染
    @Published var phase: QwenDownloadPhase = .idle

    /// 给界面用的一行状态：每次求值都走一遍 tr()，切语言即刻跟上（不是快照）
    var statusText: String { phase.statusText }

    private static let defaultHosts = ["https://hf-mirror.com", "https://huggingface.co"]

    private let hosts = QwenModelDownloader.defaultHosts
    private var hostIndex = 0
    /// 这一轮里有没有哪个镜像把清单给全了、但解析出来是空的（决定最终失败话术）
    private var sawEmptyManifest = false
    private var repo = ""
    private var destDir: URL!
    private var files: [(path: String, size: Int64)] = []
    private var fileIndex = 0
    private var completedBytes: Int64 = 0
    private var totalBytes: Int64 = 1
    private var session: URLSession?
    private var currentTask: URLSessionDownloadTask?
    private var cancelled = false

    static func remoteSHAKey(_ repo: String) -> String { "qwenRemoteSHA_" + repo }
    static func remoteModifiedKey(_ repo: String) -> String { "qwenRemoteModified_" + repo }

    func download(repo: String, force: Bool = false) {
        guard !isDownloading else { return }
        self.repo = repo
        self.destDir = QwenModels.localDirectory(for: repo)
        if force {
            try? FileManager.default.removeItem(at: destDir)
        }
        hostIndex = 0
        sawEmptyManifest = false
        fileIndex = 0
        completedBytes = 0
        cancelled = false
        isDownloading = true
        progress = 0
        phase = .fetchingList
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        fetchFileList()
    }

    func cancel() {
        cancelled = true
        currentTask?.cancel()
        session?.invalidateAndCancel()
        session = nil
        isDownloading = false
        phase = .cancelled
    }

    // MARK: - 文件清单

    /// HF 仓库里的一个文件（路径 + 字节数）。升级校验也照这张清单逐个核大小，
    /// 所以解析必须和下载走同一段代码——两份实现早晚会对不上。
    struct ManifestFile: Equatable {
        let path: String
        let size: Int64
    }

    /// HF `/api/models/<repo>/tree/main` 的响应 → 会下载的文件清单。
    /// 纯函数（不联网、不碰磁盘）以便单测：跳过隐藏文件与 .md 文档，与下载行为逐条一致。
    static func parseManifest(_ data: Data) -> [ManifestFile] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var list: [ManifestFile] = []
        for item in array {
            guard (item["type"] as? String) == "file",
                  let path = item["path"] as? String else { continue }
            // 跳过隐藏文件和文档
            if path.hasPrefix(".") || path.lowercased().hasSuffix(".md") { continue }
            let size = (item["size"] as? Int64) ?? Int64((item["size"] as? Int) ?? 0)
            list.append(ManifestFile(path: path, size: size))
        }
        return list
    }

    /// 取一个仓库的文件清单（镜像源顺序回退）。completion 在主线程，失败给 nil。
    /// 供升级校验用——「清单里的文件是否都在本地、大小是否一致」是最便宜的一道验证。
    static func fetchManifest(repo: String,
                              hosts: [String] = defaultHosts,
                              completion: @escaping ([ManifestFile]?) -> Void) {
        func attempt(_ index: Int) {
            guard index < hosts.count,
                  let url = URL(string: "\(hosts[index])/api/models/\(repo)/tree/main") else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            URLSession.shared.dataTask(with: request) { data, response, error in
                guard error == nil,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data else {
                    attempt(index + 1)
                    return
                }
                let list = parseManifest(data)
                guard !list.isEmpty else {
                    attempt(index + 1)
                    return
                }
                DispatchQueue.main.async { completion(list) }
            }.resume()
        }
        attempt(0)
    }

    private func fetchFileList() {
        guard hostIndex < hosts.count else {
            // 镜像都试完了：清单能取回来但内容是空的 → 说"仓库为空"；压根没取回来 → 说"拿不到清单"
            finishWithError(sawEmptyManifest ? .emptyRepo : .fileListUnavailable)
            return
        }
        let url = URL(string: "\(hosts[hostIndex])/api/models/\(repo)/tree/main")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self, !self.cancelled else { return }
                guard error == nil,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data else {
                    self.hostIndex += 1
                    self.fetchFileList()
                    return
                }
                let list = Self.parseManifest(data).map { (path: $0.path, size: $0.size) }
                guard !list.isEmpty else {
                    // 清单解析不出来（响应异常 / 仓库为空）就换下一个镜像；都试完了才由上面那道
                    // guard 收口——绝不因为一个镜像返回怪东西就判定仓库有问题。记下"至少有一个
                    // 镜像把清单给全了、但里面是空的"，让最后那句失败话术说得准（仓库空 ≠ 拿不到清单）
                    self.sawEmptyManifest = true
                    self.hostIndex += 1
                    self.fetchFileList()
                    return
                }
                self.files = list
                self.totalBytes = max(1, list.reduce(0) { $0 + $1.1 })
                self.downloadNextFile()
            }
        }
        task.resume()
    }

    // MARK: - 逐文件下载

    private func downloadNextFile() {
        guard !cancelled else { return }
        guard fileIndex < files.count else {
            isDownloading = false
            progress = 1
            phase = .completed(fileCount: files.count)
            session?.finishTasksAndInvalidate()
            session = nil
            recordRemoteVersion()
            return
        }
        let file = files[fileIndex]
        let url = URL(string: "\(hosts[hostIndex])/\(repo)/resolve/main/\(file.path)")!

        // 已存在且大小一致的文件直接跳过（断点续传粒度=文件）
        let dest = destDir.appendingPathComponent(file.path)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let size = attrs[.size] as? Int64, size == file.size, file.size > 0 {
            completedBytes += file.size
            fileIndex += 1
            progress = Double(completedBytes) / Double(totalBytes)
            downloadNextFile()
            return
        }

        if session == nil {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        }
        phase = .startingFile(fileIndex: fileIndex, fileCount: files.count, file: file.path)
        let task = session!.downloadTask(with: url)
        currentTask = task
        task.resume()
    }

    /// 下载完成后记录远端仓库版本，供"检查更新"对比。
    private func recordRemoteVersion() {
        let repo = self.repo
        Self.fetchRemoteVersion(repo: repo, hosts: hosts) { version in
            guard let version = version else { return }
            Self.store(version, for: repo)
        }
    }

    /// 检查 HF 仓库是否比本地下载时更新。completion 在主线程回调 (是否有更新, 说明文字)。
    static func checkForUpdate(repo: String, completion: @escaping (Bool, String) -> Void) {
        fetchRemoteVersion(repo: repo) { version in
            guard let remote = version else {
                completion(false, tr("检查失败：无法连接模型仓库", "Check failed — cannot reach the model repo"))
                return
            }

            let defaults = UserDefaults.standard
            let localSHA = defaults.string(forKey: remoteSHAKey(repo))
            let localModified = defaults.string(forKey: remoteModifiedKey(repo))
            let modelPath = QwenModels.localDirectory(for: repo).appendingPathComponent("model.safetensors").path
            let hasLocalModel = FileManager.default.fileExists(atPath: modelPath)

            if let remoteSHA = remote.sha, let localSHA = localSHA {
                if remoteSHA == localSHA {
                    completion(false, tr("已是最新（远端版本 ", "Up to date (remote ") + remote.displayLabel + tr("）", ")"))
                } else {
                    completion(true, tr("发现新版本：远端 ", "Update available: remote ") + remote.displayLabel + tr("，本地 ", ", local ") + String(localSHA.prefix(8)) + tr("。点「重新下载 / 更新」", ". Click Re-download to update"))
                }
                return
            }

            if let remoteModified = remote.lastModified, let localModified = localModified {
                if remoteModified == localModified {
                    completion(false, tr("已是最新（远端版本 ", "Up to date (remote ") + remote.displayLabel + tr("）", ")"))
                } else {
                    completion(true, tr("发现新版本：远端 ", "Update available: remote ") + remote.displayLabel + tr("，本地 ", ", local ") + String(localModified.prefix(10)) + tr("。点「重新下载 / 更新」", ". Click Re-download to update"))
                }
                return
            }

            if hasLocalModel {
                completion(false, tr("本地模型没有版本记录；点「重新下载 / 更新」一次即可建立更新基准", "No local version record — click Re-download once to set a baseline"))
            } else {
                completion(false, tr("模型尚未下载；先点「下载模型」", "Model not downloaded yet — click Download first"))
            }
        }
    }

    private struct RemoteVersion {
        let sha: String?
        let lastModified: String?

        var displayLabel: String {
            if let sha = sha, !sha.isEmpty {
                return String(sha.prefix(8))
            }
            if let lastModified = lastModified, !lastModified.isEmpty {
                return String(lastModified.prefix(10))
            }
            return tr("未知", "unknown")
        }
    }

    private static func store(_ version: RemoteVersion, for repo: String) {
        let defaults = UserDefaults.standard
        if let sha = version.sha {
            defaults.set(sha, forKey: remoteSHAKey(repo))
        }
        if let modified = version.lastModified {
            defaults.set(modified, forKey: remoteModifiedKey(repo))
        }
    }

    private static func fetchRemoteVersion(repo: String,
                                           hosts: [String] = defaultHosts,
                                           completion: @escaping (RemoteVersion?) -> Void) {
        func attempt(_ index: Int) {
            guard index < hosts.count else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            guard let url = URL(string: "\(hosts[index])/api/models/\(repo)") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            URLSession.shared.dataTask(with: request) { data, response, error in
                guard error == nil,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      ((json["sha"] as? String) != nil || (json["lastModified"] as? String) != nil) else {
                    attempt(index + 1)
                    return
                }
                let version = RemoteVersion(sha: json["sha"] as? String,
                                            lastModified: json["lastModified"] as? String)
                DispatchQueue.main.async {
                    completion(version)
                }
            }.resume()
        }
        attempt(0)
    }

    private func finishWithError(_ failure: QwenDownloadFailure) {
        isDownloading = false
        phase = .failed(failure)
        session?.finishTasksAndInvalidate()
        session = nil
    }

    // MARK: - URLSessionDownloadDelegate（delegateQueue = main）

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard !cancelled else { return }
        let done = completedBytes + totalBytesWritten
        progress = min(1, Double(done) / Double(totalBytes))
        phase = .downloading(fileIndex: fileIndex, fileCount: files.count,
                             doneBytes: done, totalBytes: totalBytes)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let http = downloadTask.response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            retryOrFail()
            return
        }
        let file = files[fileIndex]
        let dest = destDir.appendingPathComponent(file.path)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            finishWithError(.saveFailed(detail: error.localizedDescription))
            return
        }
        completedBytes += max(file.size, 0)
        fileIndex += 1
        downloadNextFile()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        retryOrFail()
    }

    private func retryOrFail() {
        guard !cancelled else { return }
        if hostIndex + 1 < hosts.count {
            // 换镜像源重试当前文件
            hostIndex += 1
            downloadNextFile()
        } else {
            finishWithError(.allMirrorsFailed)
        }
    }
}
