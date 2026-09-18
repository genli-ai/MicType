import AppKit

/// 剪贴板的**全 flavour** 快照：一份 pasteboard 可能有多个 item，每个 item 又有多种 type
/// （纯文本 + RTF + HTML + TIFF + 文件 URL…）。只快照 `.string` 再写回，等于把其余 flavour
/// 全部抹掉——原剪贴板是图片/文件时更是直接归零。这里遍历 `pasteboardItems` 把每个 item 的
/// 每种 type 的 data 都存下来，恢复时原样重建。
struct ClipboardSnapshot {

    /// 每个元素 = 一个 pasteboard item 的 [type: data]，顺序即 item 顺序
    private let items: [[(NSPasteboard.PasteboardType, Data)]]
    /// 快照那一刻的 changeCount——所有"剪贴板还是我认识的那一份吗"的判据都用它，
    /// 字符串相等判据会被"用户恰好复制了同样的文字"和多 flavour 内容骗过去。
    let changeCount: Int
    /// 拿不到 data 的 flavour 数（promise 类型 / provider 已失效），只用于日志
    let skippedTypes: Int
    private let byteCount: Int

    var itemCount: Int { items.count }
    var typeCount: Int { items.reduce(0) { $0 + $1.count } }
    var isEmpty: Bool { items.isEmpty }

    /// 只有 type 名，绝不含剪贴板内容——日志里永远看不到用户复制了什么
    var typeSummary: String {
        var seen: [String] = []
        for item in items {
            for (type, _) in item where !seen.contains(type.rawValue) {
                seen.append(type.rawValue)
            }
        }
        let head = seen.prefix(6).joined(separator: ",")
        return seen.count > 6 ? head + ",+\(seen.count - 6)" : head
    }

    /// promise 类型（file promise / 懒加载 provider）读 data 会触发 provider 回调，
    /// 跨进程时既慢又常常拿不到东西；直接跳过，不为一个读不了的 flavour 放弃整份快照。
    private static func isPromised(_ type: NSPasteboard.PasteboardType) -> Bool {
        type.rawValue.lowercased().contains("promise")
    }

    static func capture(_ pb: NSPasteboard = .general) -> ClipboardSnapshot {
        let count = pb.changeCount
        var captured: [[(NSPasteboard.PasteboardType, Data)]] = []
        var skipped = 0
        var bytes = 0
        for item in pb.pasteboardItems ?? [] {
            var flavours: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard !isPromised(type) else { skipped += 1; continue }
                guard let data = item.data(forType: type) else { skipped += 1; continue }
                flavours.append((type, data))
                bytes += data.count
            }
            if !flavours.isEmpty { captured.append(flavours) }
        }
        return ClipboardSnapshot(items: captured, changeCount: count,
                                 skippedTypes: skipped, byteCount: bytes)
    }

    /// 原样写回，返回写入后的 changeCount（调用方要用它继续跟踪"剪贴板还是不是这一份"）。
    /// 快照为空说明当时剪贴板本来就是空的（或只剩 promise）→ 清空，别把我们的输出留在那儿。
    @discardableResult
    func restore(to pb: NSPasteboard = .general) -> Int {
        guard !items.isEmpty else { return pb.clearContents() }
        let rebuilt: [NSPasteboardItem] = items.map { flavours in
            let item = NSPasteboardItem()
            for (type, data) in flavours { item.setData(data, forType: type) }
            return item
        }
        pb.clearContents()
        pb.writeObjects(rebuilt)
        return pb.changeCount
    }

    var logSummary: String {
        "items=\(itemCount) types=\(typeCount) bytes=\(byteCount) skipped=\(skippedTypes) [\(typeSummary)]"
    }
}

/// 把文字插入到当前光标处：写入剪贴板 → 模拟 ⌘V → 恢复原剪贴板。
/// 设计原则：宁可让用户多按一次 ⌘V，也绝不让文字消失。
enum TextInserter {

    enum Outcome {
        case pasted          // 已粘贴到目标
        case clipboardOnly   // 没把握粘贴成功，文本保留在剪贴板里
    }

    /// 粘贴时序档：focus 沉淀 / 写剪贴板沉淀 / ⌘V 按住时长。
    /// fast = 目标本就在前台且非冷启动（焦点没动，几乎无需等待）；
    /// normal = 需要重新激活的常态；conservative = 冷启动首次粘贴（输入框可能还没吃键，给足时间）。
    private struct PasteTiming {
        let focusDelay: Double
        let pasteDelay: Double
        let keyHold: Double
        static let fast = PasteTiming(focusDelay: 0.0, pasteDelay: 0.08, keyHold: 0.03)
        static let normal = PasteTiming(focusDelay: 0.25, pasteDelay: 0.18, keyHold: 0.03)
        static let conservative = PasteTiming(focusDelay: 0.75, pasteDelay: 0.35, keyHold: 0.12)
    }

    // MARK: - 恢复会话（全 App 唯一，只在主线程读写）
    //
    // 旧实现的 `asyncAfter(+5.0)` 不可取消：连着听写两次、间隔 <5s 时，第二次会把
    // **MicType 自己刚写进去的输出**当成"用户的原剪贴板"快照下来，用户真正的原内容被链化覆盖，
    // 永久丢失。所以恢复任务收敛成单一可取消的 DispatchWorkItem，由 TextInserter 持有：
    // 新插入先取消旧任务，并在剪贴板确实还是我们上次写的那一份时**沿用最早的那份非自产快照**。

    /// 待执行的恢复任务；nil = 当前没有待恢复的会话
    private static var pendingRestore: DispatchWorkItem?
    /// 待恢复的原剪贴板（永远是最早的非自产快照）
    private static var pendingSnapshot: ClipboardSnapshot?
    /// 我们自己最后一次写入剪贴板之后的 changeCount；-1 = 没在跟踪
    private static var ourChangeCount: Int = -1

    /// 供 SelectionReader 的 ⌘C 兜底调用：它临时改了剪贴板又原样写回，内容没变但 changeCount 必然跳，
    /// 不同步过来的话待恢复任务会误判成"用户复制了新东西"而放弃恢复，用户的原剪贴板就此丢失。
    static func clipboardRewritten(previousChangeCount: Int, newChangeCount: Int) {
        guard pendingRestore != nil, ourChangeCount == previousChangeCount else { return }
        ourChangeCount = newChangeCount
        Log.info("Clipboard session follows rewrite change=\(newChangeCount)")
    }

    /// 放弃当前待恢复会话：用于"文本要留在剪贴板给用户 ⌘V"的路径——
    /// 此时恢复原剪贴板会把用户正要粘的文字擦掉，宁可不恢复。
    private static func dropPendingRestore(reason: String) {
        guard pendingRestore != nil else { return }
        pendingRestore?.cancel()
        pendingRestore = nil
        pendingSnapshot = nil
        ourChangeCount = -1
        Log.info("Clipboard pending restore dropped reason=\(reason)")
    }

    /// targetBundleID：录音开始时的目标应用。
    /// 如果用户在识别/润色期间切走了窗口，先把目标应用拉回前台、确认到位后再粘贴；
    /// 拉不回来就把文本留在剪贴板并告知用户。completion 在主线程回调。
    static func insert(_ text: String, targetBundleID: String = "",
                       allowClipboardRestore: Bool = true,
                       conservativePaste: Bool = false,
                       completion: @escaping (Outcome) -> Void) {
        guard Permissions.isAccessibilityTrusted else {
            putOnClipboard(text)
            completion(.clipboardOnly)
            return
        }

        guard !targetBundleID.isEmpty else {
            // 不知道目标 App：无法确认焦点稳定，按 normal/conservative 时序直接粘进当前焦点
            pasteIntoCurrentFocus(text, timing: conservativePaste ? .conservative : .normal,
                                  allowRestore: allowClipboardRestore, completion: completion)
            return
        }

        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: targetBundleID).first else {
            putOnClipboard(text)
            completion(.clipboardOnly)
            return
        }

        let alreadyFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetBundleID

        // 常态（轻点听写，用户一直停在同一个 App，模型已热）：目标本就在前台 → 不要重新激活。
        // 重新激活会改变 key window、把浏览器/Electron（Chrome/Gmail/VSCode/Slack…）正聚焦的
        // 输入框 blur 掉，光标当场消失。直接快速粘贴即可。
        let tInsert = DispatchTime.now()
        if alreadyFrontmost && !conservativePaste {
            pasteIntoCurrentFocus(text, timing: .fast, allowRestore: allowClipboardRestore) { outcome in
                Log.info("Timing insert=\(Log.ms(since: tInsert))ms path=fast")
                completion(outcome)
            }
            return
        }

        // 需要把目标拉回前台（用户中途切走，或冷启动首次粘贴"App 在前台但输入框还没吃键"）。
        // 去掉 .activateAllWindows——它会抬起该 App 的全部窗口、可能把焦点落到错误的窗口；
        // 只激活当前/最前窗口，保住光标所在窗口。冷启动仍走 conservative 长时序（保留旧可靠性修复）。
        app.activate(options: [])
        waitForFrontmost(targetBundleID, attemptsLeft: conservativePaste ? 16 : 8) { arrived in
            if arrived {
                pasteIntoCurrentFocus(text, timing: conservativePaste ? .conservative : .normal,
                                      allowRestore: allowClipboardRestore) { outcome in
                    Log.info("Timing insert=\(Log.ms(since: tInsert))ms path=\(conservativePaste ? "activate-cold" : "activate")")
                    completion(outcome)
                }
            } else {
                putOnClipboard(text)
                completion(.clipboardOnly)
            }
        }
    }

    /// 把目标应用拉回前台（已经在前台就立刻回调 true）。
    /// 给「先要对目标应用发按键、再走正常插入」的流程用（P9 换回识别原文：先 ⌘Z 再插 raw）——
    /// 从状态栏菜单点下来时前台很可能已经是 MicType 自己，不先拉回去按键会落到错误的应用上。
    static func bringToFront(_ bundleID: String, completion: @escaping (Bool) -> Void) {
        guard !bundleID.isEmpty else { completion(false); return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            completion(true)
            return
        }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else {
            completion(false)
            return
        }
        // 同 insert()：不要 .activateAllWindows，保住用户光标所在的那个窗口
        app.activate(options: [])
        waitForFrontmost(bundleID, attemptsLeft: 8, completion: completion)
    }

    /// 轮询等待目标应用到达前台（每 0.15s 一次，最多约 1.2s）
    private static func waitForFrontmost(_ bundleID: String, attemptsLeft: Int,
                                         completion: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            completion(true)
            return
        }
        guard attemptsLeft > 0 else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            waitForFrontmost(bundleID, attemptsLeft: attemptsLeft - 1, completion: completion)
        }
    }

    private static func putOnClipboard(_ text: String) {
        // 文本留在剪贴板等用户 ⌘V：任何待恢复任务都必须放弃，否则 5 秒后把它擦掉
        dropPendingRestore(reason: "text-left-on-clipboard")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func pasteIntoCurrentFocus(_ text: String, timing: PasteTiming,
                                              allowRestore: Bool,
                                              completion: @escaping (Outcome) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.focusDelay) {
            performPaste(text, timing: timing, allowRestore: allowRestore) {
                completion(.pasted)
            }
        }
    }

    private static func performPaste(_ text: String, timing: PasteTiming, allowRestore: Bool,
                                     completion: (() -> Void)? = nil) {
        let pasteboard = NSPasteboard.general
        let wantRestore = allowRestore && Settings.shared.restoreClipboard

        // 先取消上一次还没跑的恢复任务，再决定这次用哪份快照
        pendingRestore?.cancel()
        pendingRestore = nil

        var snapshot: ClipboardSnapshot? = nil
        if wantRestore {
            if let carried = pendingSnapshot, pasteboard.changeCount == ourChangeCount {
                // 剪贴板里躺的还是 MicType 上次写的输出 → 用户的原内容在那份旧快照里，沿用它。
                // 绝不能在这里重新快照，否则"我们自己的输出"会被当成用户的原剪贴板。
                snapshot = carried
                Log.info("Clipboard snapshot carried over \(carried.logSummary)")
            } else {
                let fresh = ClipboardSnapshot.capture(pasteboard)
                snapshot = fresh
                Log.info("Clipboard snapshot \(fresh.logSummary)")
            }
        } else if pendingSnapshot != nil {
            Log.info("Clipboard pending restore dropped reason=restore-disabled")
        }
        pendingSnapshot = snapshot

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ourChangeCount = pasteboard.changeCount

        // 给剪贴板写入留一点时间，再发送 ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.pasteDelay) {
            sendCmdV(keyHold: timing.keyHold) {
                completion?()
            }
            guard let snapshot = snapshot else { return }
            let work = DispatchWorkItem {
                // 判据用 changeCount 而不是字符串相等：多 flavour 的剪贴板比不出来，
                // 而"用户恰好复制了一模一样的文字"会被字符串判据误判成我们的输出。
                guard pasteboard.changeCount == ourChangeCount else {
                    Log.info("Clipboard restore skipped reason=changed-by-user")
                    clearSession()
                    return
                }
                let after = snapshot.restore(to: pasteboard)
                Log.info("Clipboard restored items=\(snapshot.itemCount) types=\(snapshot.typeCount)"
                         + (snapshot.isEmpty ? " (was empty → cleared)" : "") + " change=\(after)")
                clearSession()
            }
            pendingRestore = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
        }
    }

    /// 恢复任务跑完后收尾；只在它仍是当前任务时清（新插入已经换过就别动）
    private static func clearSession() {
        pendingRestore = nil
        pendingSnapshot = nil
        ourChangeCount = -1
    }

    /// 给前台应用发一次 ⌘Z。只发一次，绝不连发：各家应用的撤销粒度不一样，
    /// 多按一次很可能把用户自己之前的编辑也吃掉——宁可撤不干净，也不越界。
    static func sendUndo(completion: (() -> Void)? = nil) {
        // 6 = kVK_ANSI_Z
        sendCommandKey(virtualKey: 6, keyHold: 0.03, completion: completion)
    }

    private static func sendCmdV(keyHold: Double = 0.03, completion: (() -> Void)? = nil) {
        // 9 = kVK_ANSI_V
        sendCommandKey(virtualKey: 9, keyHold: keyHold, completion: completion)
    }

    private static func sendCommandKey(virtualKey: CGKeyCode, keyHold: Double,
                                       completion: (() -> Void)? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            completion?()
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + keyHold) {
            keyUp.post(tap: .cghidEventTap)
            completion?()
        }
    }

}
