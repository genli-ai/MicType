import AppKit

/// 轻量更新检查 + 应用内自更新：查 GitHub Releases latest → 比版本 → 下载安装包到「下载」文件夹，
/// 再由用户点一下「立即安装并重启」完成 解压 → 验签（证书链锚定 Apple + 本 Team）→ 替换自身 → 重开。
/// 优先下载公证过的 DMG（应用内更新也零警告）；没有 DMG 时回退 Developer ID 签名的 zip。
/// 不引入 Sparkle：替换逻辑只有一段 bash，看得见、可回滚（新版先拷到旁边，两次同卷改名完成交换），
/// 失败结果写成标记文件留给下次启动的自己念（这时 App 已经退出，没别的办法回话）。
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
        URLSession.shared.downloadTask(with: url) { tempURL, response, error in
            if let error = error {
                Log.warn("Update download failed: \(error.localizedDescription)")
                finish(.failed(error.localizedDescription))
                return
            }
            guard let tempURL = tempURL else {
                finish(.failed(tr("下载失败", "Download failed")))
                return
            }
            // URLSession 只把"传输失败"算 error：404/403/5xx 一样会给一个临时文件，
            // 里面装的是 GitHub 的错误页。不看状态码就会把这几 KB 的 HTML 当安装包搬进
            // 「下载」文件夹、点亮「立即安装并重启」，用户最后只看到一句"解压失败"。
            // 限流兜底那条路更需要这一刀：它按命名规矩硬拼下载地址，没有资产清单可核对。
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Log.warn("Update download HTTP \(http.statusCode) for \(name)")
                let hint = http.statusCode == 404
                    ? tr("发布页上没有 \(name)（HTTP 404），请点「发布页」手动下载",
                         "\(name) is not on the release page (HTTP 404) — use the Releases button to download manually")
                    : tr("下载失败（HTTP \(http.statusCode)），请点「发布页」手动下载",
                         "Download failed (HTTP \(http.statusCode)) — use the Releases button to download manually")
                finish(.failed(hint))
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
                // 上一次的条子清掉，免得这次脚本还没来得及写结果、下次启动却念出一条旧消息
                try? FileManager.default.removeItem(at: installResultFile)
                try launchInstaller(newApp: newApp, target: target, stage: stage, version: version)

                DispatchQueue.main.async {
                    Log.info("Self-update: installer detached, quitting for v\(version)")
                    NSApp.terminate(nil)
                    // terminate 正常一定成功；万一没退成（被拦下 / 被用户取消），脚本等 30 秒后会放弃，
                    // 而界面会永远停在"安装中…"。给一个出口，让用户知道这次没装、可以重试。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        fail(tr("没能退出当前实例，升级已取消——当前这份没有被改动，可以再试一次",
                                "Could not quit this instance, so the update was cancelled — this copy is untouched; try again"))
                    }
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

    /// 发布包必须满足的代码签名要求（designated requirement）：
    /// 证书链锚定到 **Apple 根**（anchor apple generic），且叶证书属于我们这个 Team。
    ///
    /// 为什么不能只比对 `codesign -dv` 里那行 TeamIdentifier：那只是叶证书的 OU 字段，
    /// 任何人拿自签证书都能把它写成 8568XNW6L3；而 `codesign --verify` 只验"签名与内容自洽"，
    /// 根本不做证书链信任评估（实测：一个 ad-hoc 签名的假 app 也能 --verify 通过）。
    /// 也就是说，旧的两道关加起来并不能证明这个 bundle 出自我们手里。
    /// 只有 `-R '=anchor apple generic ...'` 这一句才真的要求链到 Apple。
    ///
    /// 为什么不再加一道 `spctl --assess`：公证不是每版都做（见发布流程），拿它当硬闸会把
    /// 正常的 Developer ID 版本一并拦掉；证书链 + Team + bundle id 这三道已经足够。
    static var releaseRequirement: String {
        "=anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamID)\""
    }

    /// 三道关：Apple 签发的本 Team 证书（--verify --deep --strict -R）、bundle id 与自己一致。
    /// 任何一道不过就拒装——用户手里那个能用的版本比"装上一个来路不明的 app"重要得多。
    private static func verifySignature(of app: URL) throws {
        let verify = run("/usr/bin/codesign",
                         ["--verify", "--deep", "--strict", "-R", releaseRequirement, app.path])
        guard verify.status == 0 else {
            // 顺手把签名者报出来：用户才分得清拒的是"没签名"、"别人的 Team"还是"自签证书冒充我们"
            let team = signingTeam(of: app)
            let shown = team.isEmpty ? tr("未签名", "unsigned") : team
            throw MTError(tr("新版本签名校验未通过（签名者：\(shown)；要求 Apple 签发给 \(expectedTeamID) 的证书），已拒绝安装：\(brief(verify.output))",
                             "Signature check failed (signed by: \(shown); requires an Apple-issued certificate for \(expectedTeamID)) — install refused: \(brief(verify.output))"))
        }
        let team = signingTeam(of: app)

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

    /// 只用来做提示文案与日志——**不作为安全判据**（叶证书 OU 可被自签证书伪造，
    /// 真正的判据是上面那条 releaseRequirement）
    private static func signingTeam(of app: URL) -> String {
        let detail = run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        let team = detail.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) } ?? ""
        return team == "not set" ? "" : team
    }

    // MARK: 替换 + 重启

    /// 把替换动作交给一段独立 bash：它比我们活得久，等我们退出后才动 bundle。
    /// 失败可回滚（新版先拷到目标旁边的 .new，拷不成时原来那份一个字节都没动过），
    /// 结果写进 resultFile 供下次启动读取。
    private static func launchInstaller(newApp: URL, target: URL, stage: URL, version: String) throws {
        try? FileManager.default.createDirectory(at: Log.logsDirectory, withIntermediateDirectories: true)
        let logFile = Log.logsDirectory.appendingPathComponent("update-install.log")
        let script = stage.appendingPathComponent("install.sh")
        let body = installerScript(pid: ProcessInfo.processInfo.processIdentifier,
                                   newApp: newApp, target: target, stage: stage,
                                   logFile: logFile, resultFile: installResultFile, version: version)
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
                                        stage: URL, logFile: URL,
                                        resultFile: URL, version: String) -> String {
        """
        #!/bin/bash
        # MicType 自更新脚本（由 App 生成在临时目录，安装完自删）
        # 等主进程退出 → ditto 新 bundle 到目标旁边的 .new → 旧的进废纸篓 → .new 改名就位 → 重开
        exec >>\(shq(logFile.path)) 2>&1
        PID=\(pid)
        APP=\(shq(target.path))
        NEW=\(shq(newApp.path))
        STAGE=\(shq(stage.path))
        RESULT=\(shq(resultFile.path))
        VERSION=\(shq(version))
        SELF="$0"
        STAGED="$APP.new"
        TRASH="$HOME/.Trash/MicType-$(date '+%Y%m%d-%H%M%S').app"
        echo "=== $(date '+%Y-%m-%dT%H:%M:%S') MicType self-update: $NEW -> $APP"

        # 收尾统一走这里：
        # 1) 把结果写成标记文件——脚本比 App 活得久，失败时 App 早就退了，没人能把失败回传到界面，
        #    只能留一张条子给下次启动的自己念（见 consumePreviousInstallResult）。
        # 2) 清 stage：过去只有成功路径清，三条 abort 各留一份解压好的 app bundle 在临时目录。
        #    本脚本自己就在 $STAGE 里，所以照旧延后到后台再删，别抽掉 bash 正在读的文件。
        finish() {
            printf '%s' "$2" > "$RESULT" 2>/dev/null || true
            ( sleep 3; /bin/rm -rf "$STAGE" "$SELF" ) >/dev/null 2>&1 &
            exit "$1"
        }

        # 等自己退出，最多 30 秒；没退出就什么都不做（绝不换掉正在跑的 bundle）
        for _ in $(seq 1 150); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$PID" 2>/dev/null; then
            echo "old instance (pid $PID) still running after 30s — abort"
            finish 1 "FAIL:still-running"
        fi

        # 先把新 bundle 拷到目标同目录的 .new（同卷），再用两次 rename 完成交换：
        # 旧版进废纸篓与新版就位都是原子的 rename，中间不存在"哪儿都没有 MicType"的真空窗口，
        # 拷贝失败时原来那份一个字节都没被动过。
        /bin/rm -rf "$STAGED"
        if ! /usr/bin/ditto "$NEW" "$STAGED"; then
            echo "copying the new bundle next to $APP failed — nothing was touched"
            /bin/rm -rf "$STAGED"
            /usr/bin/open -n "$APP" || true
            finish 1 "FAIL:copy-failed"
        fi

        # 下载来的包可能带隔离标记，不清掉会被 Gatekeeper 当成"首次打开"再拦一次
        /usr/bin/xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null || true

        if [ -e "$APP" ] && ! /bin/mv "$APP" "$TRASH"; then
            echo "moving the old bundle to Trash failed — reopening the old version"
            /bin/rm -rf "$STAGED"
            /usr/bin/open -n "$APP" || true
            finish 1 "FAIL:move-failed"
        fi

        if ! /bin/mv "$STAGED" "$APP"; then
            echo "swapping in the new bundle failed — rolling back from Trash"
            # 只在原路径确实空着时才放回来：旧版直接 mv 进一个残留目录会变成
            # MicType.app/MicType-xxx.app 这种套娃，接着被 open 打开一个坏包
            if [ ! -e "$APP" ] && [ -e "$TRASH" ]; then
                /bin/mv "$TRASH" "$APP"
            fi
            /usr/bin/open -n "$APP" || true
            finish 1 "FAIL:swap-failed"
        fi

        echo "installed -> $APP"
        /usr/bin/open -n "$APP" || echo "relaunch failed — open it from Finder"
        finish 0 "OK:$VERSION"
        """
    }

    // MARK: 上一次安装的结果（脚本 → 下次启动的 App）

    /// 安装脚本写给下次启动的自己的一张条子
    static var installResultFile: URL {
        Paths.appSupportDir.appendingPathComponent("last-update-result")
    }

    /// 上一次自更新的下场。
    ///
    /// 4.1.1 之前成功那一档是 `nil`——自更新**悄无声息**地换完版本、重开，屏幕上一个字都没有。
    /// 用户 2026-09-20 的反馈正是这一条：「自动更新完成后也没有一个提示告诉提示完成」。
    /// 所以成功也要带着版本号回来，由 AppDelegate 闪一句「已更新到 x.y.z」。
    enum PreviousInstall: Equatable {
        /// 装好了。版本号取自条子（脚本写的那一行），只用来对照，界面上那句仍以本 bundle 为准
        case installed(version: String)
        /// 没装成：一句给用户看的话（含下一步）
        case failed(message: String)
    }

    /// 启动时读一次并删掉。
    /// 为什么需要它：installAndRelaunch 启动脚本后立刻 terminate，失败回调从那一刻起
    /// 永远不可能再触发；脚本的三条 abort 路径里有两条还会把**旧版**重新打开，
    /// 用户看到 MicType 消失又回来，完全有理由以为升级成功了。
    static func consumePreviousInstallResult() -> PreviousInstall? {
        let file = installResultFile
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: file)
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("OK:") {
            let version = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            Log.info("Previous self-update installed \(version)")
            return .installed(version: version)
        }
        let code = line.hasPrefix("FAIL:") ? String(line.dropFirst(5)) : line
        Log.warn("Previous self-update failed: \(code)")
        return .failed(message: describeInstallFailure(code))
    }

    /// 自更新装好之后那一句提示。**版本号取本 bundle**——条子是上一个进程写的，
    /// 真正跑起来的是哪一份只有现在这个进程知道（回滚过的话两者会对不上）。
    static func installedNoticeCopy(version: String = currentVersion) -> String {
        tr("已更新到 ", "Updated to ") + version
    }

    /// 提示晚一点再闪：启动这一刻引导 / 权限 / 模型预加载都在抢主线程，
    /// 一闪而过的悬浮窗会被它们盖掉，等于没提示。
    static let installedNoticeDelay: TimeInterval = 3
    /// 停留时长：比一般的「好了」长一点——这一句是要被读到的，不是背景音
    static let installedNoticeDuration: TimeInterval = 2.5

    private static func describeInstallFailure(_ code: String) -> String {
        let reason: String
        switch code {
        case "still-running":
            reason = tr("旧版本没有及时退出", "the old version didn't quit in time")
        case "copy-failed":
            reason = tr("复制新版本失败（磁盘空间或权限）", "copying the new version failed (disk space or permissions)")
        case "move-failed":
            reason = tr("没能把旧版本移到废纸篓", "the old version couldn't be moved to the Trash")
        case "swap-failed":
            reason = tr("替换时失败，已回滚", "the swap failed and was rolled back")
        default:
            reason = code
        }
        return tr("上次升级没有完成：\(reason)。当前这份没有被改动，可以在「关于」页重试，或到发布页手动下载。",
                  "The last update didn't finish: \(reason). This copy is untouched — retry from the About tab, or download manually from the Releases page.")
    }

    /// 清掉临时目录里的历史 stage 残留（每份是一整个解压好的 app bundle）。
    /// 只扫一小时前的：刚装完那次，脚本可能还在读自己——它自己会延后删。
    static func cleanupStaleStages() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-3600)
        let items = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items where item.lastPathComponent.hasPrefix("MicType-update-") {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard (modified ?? .distantPast) < cutoff else { continue }
            try? fm.removeItem(at: item)
            Log.info("Removed stale update stage \(item.lastPathComponent)")
        }
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
