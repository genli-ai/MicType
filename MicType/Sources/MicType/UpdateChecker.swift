import AppKit

/// 轻量更新检查 + 应用内自更新：查 GitHub Releases latest → 比版本 → 下载安装包到「下载」文件夹，
/// 再由用户点一下「立即安装并重启」完成 解压 → 验签（Developer ID + Team ID）→ 替换自身 → 重开。
/// 优先下载公证过的 DMG（应用内更新也零警告）；没有 DMG 时回退 Developer ID 签名的 zip。
/// 不引入 Sparkle：替换逻辑只有一段 bash，看得见、可回滚（失败自动把旧 bundle 从废纸篓挪回来）。
enum UpdateChecker {

    enum CheckResult {
        case upToDate(String)               // 已是最新（当前版本号）
        case downloaded(String, URL)        // 新版本号、已下载的安装包路径（dmg 或 zip）
        case failed(String)                 // 用户可读的失败原因
    }

    static let releasesPage = URL(string: "https://github.com/genli-ai/MicType/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 主线程回调
    static func checkAndDownload(completion: @escaping (CheckResult) -> Void) {
        let finish: (CheckResult) -> Void = { r in DispatchQueue.main.async { completion(r) } }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/genli-ai/MicType/releases/latest")!,
                                 timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                fallbackViaRedirect(apiError: error.localizedDescription, finish: finish)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                // GitHub API 匿名调用在共享出口 IP（国内常见）下极易 403 限流——换无限流的重定向探测
                fallbackViaRedirect(apiError: tr("GitHub API 返回异常（可能是限流）", "Unexpected API response (possibly rate-limited)"),
                                    finish: finish)
                return
            }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            Log.info("Update check latest=\(latest) current=\(currentVersion)")
            guard isNewer(latest, than: currentVersion) else {
                finish(.upToDate(currentVersion))
                return
            }

            // 优先公证过的 DMG（应用内更新也零警告），没有再回退 Developer ID 签名的 zip
            let assets = (json["assets"] as? [[String: Any]]) ?? []
            let pick: (String) -> [String: Any]? = { suffix in
                assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
            }
            guard let asset = pick("-arm64.dmg") ?? pick("-arm64.zip"),
                  let urlString = asset["browser_download_url"] as? String,
                  let assetName = asset["name"] as? String,
                  let downloadURL = URL(string: urlString) else {
                finish(.failed(tr("新版本没有可下载的安装包", "The new release has no downloadable installer")))
                return
            }

            downloadAsset(downloadURL, named: assetName, version: latest, finish: finish)
        }.resume()
    }

    private static func downloadAsset(_ url: URL, named name: String, version: String,
                                      finish: @escaping (CheckResult) -> Void) {
        URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            if let error = error {
                Log.warn("Update download failed: \(error.localizedDescription)")
                finish(.failed(error.localizedDescription))
                return
            }
            guard let tempURL = tempURL else {
                finish(.failed(tr("下载失败", "Download failed")))
                return
            }
            do {
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                let dest = downloads.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tempURL, to: dest)
                Log.info("Update downloaded \(name) -> Downloads")
                // 不再自动在 Finder 里弹出来：主路径改成「立即安装并重启」，
                // 想手动装的人点「在 Finder 中显示」——少一次没人要求的窗口跳出来
                finish(.downloaded(version, dest))
            } catch {
                finish(.failed(error.localizedDescription))
            }
        }.resume()
    }

    /// API 失败时的兜底：releases/latest 的网页入口会 302 到 /tag/vX.Y.Z——
    /// 从 Location 头解析版本（不经 API、无限流），下载地址按发布命名规矩直接构造
    private static func fallbackViaRedirect(apiError: String, finish: @escaping (CheckResult) -> Void) {
        Log.warn("Update check via API failed: \(apiError) — trying redirect probe")
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: releasesPage, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        session.dataTask(with: request) { _, response, _ in
            defer { session.finishTasksAndInvalidate() }
            guard let http = response as? HTTPURLResponse,
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let range = location.range(of: "/tag/", options: .backwards) else {
                finish(.failed(apiError))
                return
            }
            var latest = String(location[range.upperBound...])
            if latest.hasPrefix("v") || latest.hasPrefix("V") { latest.removeFirst() }
            Log.info("Update check (redirect) latest=\(latest) current=\(currentVersion)")
            guard isNewer(latest, than: currentVersion) else {
                finish(.upToDate(currentVersion))
                return
            }
            // 兜底路径（API 被限流时走这里）拿不到资产清单，无法确认 DMG 是否存在——
            // 非公证版本没有 DMG，而 zip 每个版本都有，这里稳妥用 zip；主路径才优先 DMG。
            let name = "MicType-\(latest)-arm64.zip"
            guard let url = URL(string: "https://github.com/genli-ai/MicType/releases/download/v\(latest)/\(name)") else {
                finish(.failed(apiError))
                return
            }
            downloadAsset(url, named: name, version: latest, finish: finish)
        }.resume()
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// 数字分段比较："3.2.12" vs "3.2.9" → true
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

// MARK: - 应用内自更新（解压 → 验签 → 替换自身 → 重启）

extension UpdateChecker {

    /// 发布证书的 Team ID。只有这个 Team 签出来的 bundle 才允许替换掉我们自己——
    /// 「从网上下一个 app 覆盖本机已装的 app」是全流程最危险的一步，宁可拒装也不能装错东西。
    static let expectedTeamID = "8568XNW6L3"

    /// 一步升级：解压安装包 → 校验签名与 Team ID → 交给一段 bash 换掉自身 → 终止本进程。
    /// progress / failure 都回主线程；成功时本进程会被 terminate，不会再有回调。
    static func installAndRelaunch(archive: URL,
                                   version: String,
                                   progress: @escaping (String) -> Void,
                                   failure: @escaping (String) -> Void) {
        let report: (String) -> Void = { m in DispatchQueue.main.async { progress(m) } }
        let fail: (String) -> Void = { m in
            Log.warn("Self-update aborted: \(m)")
            DispatchQueue.main.async { failure(m) }
        }

        // 用 Bundle.main.bundleURL 定位自己：/Applications 与 ~/Applications 一视同仁，
        // 也包括从 zip 直接双击运行的临时位置
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        // 先确认所在目录可写——不可写就别走到「已经把自己扔进废纸篓」那一步
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            fail(tr("没有权限写入 \(parent.path)，请手动替换",
                    "No write permission for \(parent.path) — please replace the app manually"))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent("MicType-update-\(UUID().uuidString)", isDirectory: true)
            do {
                Log.info("Self-update start: \(archive.lastPathComponent) -> \(target.path)")
                report(tr("正在解压安装包…", "Extracting the package…"))
                let newApp = try stageApp(from: archive, into: stage)

                report(tr("正在校验签名…", "Verifying the signature…"))
                try verifySignature(of: newApp)

                report(tr("正在替换并重启…", "Replacing and relaunching…"))
                try launchInstaller(newApp: newApp, target: target, stage: stage)

                DispatchQueue.main.async {
                    Log.info("Self-update: installer detached, quitting for v\(version)")
                    NSApp.terminate(nil)
                }
            } catch let e as MTError {
                try? FileManager.default.removeItem(at: stage)
                fail(e.message)
            } catch {
                try? FileManager.default.removeItem(at: stage)
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: 解压

    /// zip 用 ditto -x -k（保留签名所需的扩展属性，用 unzip 会把签名弄坏）；dmg 先挂载再 ditto 出来。
    private static func stageApp(from archive: URL, into stage: URL) throws -> URL {
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let payload = stage.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)

        switch archive.pathExtension.lowercased() {
        case "zip":
            let r = run("/usr/bin/ditto", ["-x", "-k", archive.path, payload.path])
            guard r.status == 0 else {
                throw MTError(tr("解压失败：\(brief(r.output))", "Unzip failed: \(brief(r.output))"))
            }
            guard let app = findApp(in: payload) else {
                throw MTError(tr("安装包里没有找到 MicType.app", "No MicType.app inside the package"))
            }
            return app

        case "dmg":
            let mount = stage.appendingPathComponent("mnt", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            let attach = run("/usr/bin/hdiutil",
                             ["attach", archive.path, "-nobrowse", "-readonly", "-noverify",
                              "-mountpoint", mount.path])
            guard attach.status == 0 else {
                throw MTError(tr("挂载 DMG 失败：\(brief(attach.output))", "Mounting the DMG failed: \(brief(attach.output))"))
            }
            defer {
                // 卸载必须做掉，否则失败后会留一个幽灵卷；普通卸载被占用时再来一次 -force
                if run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]).status != 0 {
                    _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
                }
            }
            guard let mounted = findApp(in: mount) else {
                throw MTError(tr("DMG 里没有找到 MicType.app", "No MicType.app inside the DMG"))
            }
            let copy = payload.appendingPathComponent(mounted.lastPathComponent)
            let r = run("/usr/bin/ditto", [mounted.path, copy.path])
            guard r.status == 0 else {
                throw MTError(tr("从 DMG 复制失败：\(brief(r.output))", "Copying out of the DMG failed: \(brief(r.output))"))
            }
            return copy

        default:
            throw MTError(tr("不认识的安装包格式：\(archive.lastPathComponent)",
                             "Unsupported package format: \(archive.lastPathComponent)"))
        }
    }

    /// 顶层找 .app，找不到再往下找一层（DMG 里偶尔会套一层目录）。
    /// 软链接一律不跟进：DMG 根目录上的「Applications」快捷方式指向 /Applications，
    /// 跟进去就会在已装的一堆 app 里乱挑一个。
    private static func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        if let app = pickApp(items) { return app }
        for sub in items where (try? sub.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true {
            let children = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
            if let app = pickApp(children) { return app }
        }
        return nil
    }

    /// 同名的优先，其次才是任意 .app（后面还有 bundle id 校验兜着）
    private static func pickApp(_ items: [URL]) -> URL? {
        items.first { $0.lastPathComponent == "MicType.app" }
            ?? items.first { $0.pathExtension == "app" }
    }

    // MARK: 验签

    /// 三道关：签名自洽（--verify --deep --strict）、Team ID 是发布证书、bundle id 与自己一致。
    /// 任何一道不过就拒装——用户手里那个能用的版本比"装上一个来路不明的 app"重要得多。
    private static func verifySignature(of app: URL) throws {
        let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else {
            throw MTError(tr("新版本签名校验未通过，已拒绝安装：\(brief(verify.output))",
                             "Signature check failed, install refused: \(brief(verify.output))"))
        }

        let detail = run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        let team = detail.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) } ?? ""
        guard team == expectedTeamID else {
            let shown = (team.isEmpty || team == "not set") ? tr("未签名", "unsigned") : team
            throw MTError(tr("签名者 Team ID 是 \(shown)，不是 \(expectedTeamID)，已拒绝安装",
                             "Signed by team \(shown), not \(expectedTeamID) — install refused"))
        }

        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let newID = info?["CFBundleIdentifier"] as? String ?? ""
        let myID = Bundle.main.bundleIdentifier ?? "com.ligen.mictype"
        guard newID == myID else {
            throw MTError(tr("安装包里的 App 标识是 \(newID)，与本机的 \(myID) 不一致，已拒绝安装",
                             "The package's bundle id \(newID) differs from \(myID) — install refused"))
        }
        let newVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        Log.info("Self-update verified: team=\(team) bundle=\(newID) version=\(newVersion)")
    }

    // MARK: 替换 + 重启

    /// 把替换动作交给一段独立 bash：它比我们活得久，等我们退出后才动 bundle。
    /// 失败可回滚（旧 bundle 先进废纸篓，ditto 不成就挪回原位并重开旧版）。
    private static func launchInstaller(newApp: URL, target: URL, stage: URL) throws {
        try? FileManager.default.createDirectory(at: Log.logsDirectory, withIntermediateDirectories: true)
        let logFile = Log.logsDirectory.appendingPathComponent("update-install.log")
        let script = stage.appendingPathComponent("install.sh")
        let body = installerScript(pid: ProcessInfo.processInfo.processIdentifier,
                                   newApp: newApp, target: target, stage: stage, logFile: logFile)
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        // 故意不 wait：这个子进程要活过我们自己（父进程退出后由 launchd 收养）
        try process.run()
        Log.info("Self-update installer launched: \(script.path)")
    }

    /// 单引号包裹的 shell 字面量（路径里可能有空格、中文、引号）
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func installerScript(pid: Int32, newApp: URL, target: URL,
                                        stage: URL, logFile: URL) -> String {
        """
        #!/bin/bash
        # MicType 自更新脚本（由 App 生成在临时目录，安装完自删）
        # 等主进程退出 → 旧 bundle 进废纸篓 → ditto 新 bundle 到原路径 → 去隔离 → 重开
        exec >>\(shq(logFile.path)) 2>&1
        PID=\(pid)
        APP=\(shq(target.path))
        NEW=\(shq(newApp.path))
        STAGE=\(shq(stage.path))
        SELF="$0"
        TRASH="$HOME/.Trash/MicType-$(date '+%Y%m%d-%H%M%S').app"
        echo "=== $(date '+%Y-%m-%dT%H:%M:%S') MicType self-update: $NEW -> $APP"

        # 等自己退出，最多 30 秒；没退出就什么都不做（绝不换掉正在跑的 bundle）
        for _ in $(seq 1 150); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$PID" 2>/dev/null; then
            echo "old instance (pid $PID) still running after 30s — abort"
            exit 1
        fi

        if [ -e "$APP" ]; then
            if ! /bin/mv "$APP" "$TRASH"; then
                echo "moving the old bundle to Trash failed — reopening the old version"
                /usr/bin/open -n "$APP" || true
                exit 1
            fi
        fi

        if ! /usr/bin/ditto "$NEW" "$APP"; then
            echo "ditto failed — rolling back from Trash"
            /bin/rm -rf "$APP"
            [ -e "$TRASH" ] && /bin/mv "$TRASH" "$APP"
            /usr/bin/open -n "$APP" || true
            exit 1
        fi

        # 下载来的包可能带隔离标记，不清掉会被 Gatekeeper 当成"首次打开"再拦一次
        /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
        echo "installed -> $APP"
        /usr/bin/open -n "$APP" || echo "relaunch failed — open it from Finder"

        # 清理放到后台并延后，避免删掉正在被 bash 读取的本脚本
        ( sleep 3; /bin/rm -rf "$STAGE" "$SELF" ) >/dev/null 2>&1 &
        exit 0
        """
    }

    // MARK: 小工具

    /// 同步跑一个命令行工具，stdout/stderr 合流。只用于 ditto / hdiutil / codesign 这类短命令。
    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        // 先读到 EOF 再 waitUntilExit：反过来会在输出撑满管道缓冲时死锁
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, out)
    }

    /// 工具输出可能很长，界面上只展示够诊断的一截（完整内容在日志里）
    private static func brief(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        return one.count > 160 ? String(one.prefix(160)) + "…" : one
    }
}
