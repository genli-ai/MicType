import AppKit
import ApplicationServices

/// 读取当前焦点元素的选中文本（纯辅助功能 API，不碰剪贴板）。
/// 读不到就返回 nil——技能路由会自动降级为普通输入，绝不误伤。
enum SelectionReader {

    /// AX 消息超时。目标应用的无障碍服务器不响应时（挂住的 Electron、远程桌面窗口、
    /// 正在转菊花的 Office），AXUIElementCopyAttributeValue 会一直按住**调用线程**，
    /// 系统默认曾长达 6 秒且各版本不一。这些读取都发生在主线程（holdPromote 同步读选区），
    /// 一卡就是：悬浮窗不刷新、松手事件排不上队、连 Esc 都失灵——Esc 拦截是挂在主 runloop 上的
    /// 事件 tap，主线程被按住会把全系统的按键一起拖住，直到系统以超时为由把 tap 禁用。
    /// 0.25s 读不到就当读不到：后面本来就有 ⌘C 兜底和"降级成无选区自由指令"的既有路径。
    private static let axMessagingTimeout: Float = 0.25

    /// systemWide element 建一次就够，顺便在这里把超时设死（这个值同时是本进程的默认超时）
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        return element
    }()

    /// ⌘C 兜底的两道时限：判定截止 0.35s（到点还没复制成就按"读不到选区"降级，绝不让指令干等），
    /// 看守截止 1.5s（⌘C 已经发出去了，晚一步落地也得有人把剪贴板还回去）。
    private static let copyPollInterval: Double = 0.05
    private static let copyDecideSeconds: Double = 0.35
    private static let copyWatchSeconds: Double = 1.5

    /// 读到的选区 + 它**能不能被原地改写**。
    ///
    /// 5.0.1 起这一位决定语音指令的结果往哪儿送（用户 2026-09-22 拍板，取代模型自己判的
    /// MODIFY / REPLY / NEW 标签）：可编辑 → ⌘V 原地替换，不可编辑 → 进剪贴板。
    /// 让模型判"这段字能不能改"本来就是问错了人——它看不见那是网页、PDF 还是输入框，
    /// 而判错的代价是把改写结果粘进一个只读的地方（什么都不会发生）或者反过来复读对方的消息。
    struct Selection {
        let text: String
        let editable: Bool
    }

    /// 焦点元素的 role + 有没有选中文字 → 能不能原地改写。**纯函数**（单测钉住）。
    ///
    /// 三个 role 是 AppKit / UIKit / Electron 里真正能吃下 ⌘V 的那几种：AXTextField（单行框）、
    /// AXTextArea（多行编辑区）、AXComboBox（带下拉的可编辑框）。网页正文是 AXGroup /
    /// AXStaticText，PDF 是 AXScrollArea——它们都能"选中"，但没有一个吃得下粘贴。
    /// **宁可判成不可编辑**：判错成"可编辑"会让 ⌘V 落空（用户眼里是结果凭空消失），
    /// 判错成"不可编辑"只是多按一次 ⌘V。
    static func roleIsEditable(_ role: String?, hasSelectedText: Bool) -> Bool {
        guard hasSelectedText, let role = role else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
    }

    static func readSelectedText() -> String? {
        readSelection()?.text
    }

    /// AX 那一条路：读到选区顺手把 role 也读了（同一个焦点元素，不多一次往返）
    static func readSelection() -> Selection? {
        guard Permissions.isAccessibilityTrusted else { return nil }

        var focusedObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedObj) == .success,
              let focusedRef = focusedObj else {
            return nil
        }
        let element = focusedRef as! AXUIElement
        // 焦点元素自己再设一次：systemWide 上设的只是本进程默认值，别赌这个元素一定继承到它
        _ = AXUIElementSetMessagingTimeout(element, axMessagingTimeout)

        var selectionObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXSelectedTextAttribute as CFString,
                                            &selectionObj) == .success,
              let text = selectionObj as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var roleObj: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString,
                                                 &roleObj) == .success
            ? roleObj as? String : nil
        return Selection(text: text,
                         editable: roleIsEditable(role, hasSelectedText: true))
    }

    /// 异步读取选区：先试 AX；失败则模拟 ⌘C 兜底（保存并恢复原剪贴板）。
    /// 适用于微信/QQ 等无障碍接口残缺的应用。completion 在主线程回调。
    ///
    /// **⌘C 兜底拿到的选区一律算不可编辑**（5.0.1）：走到这条路上说明目标应用的 AX 里
    /// 压根没有"焦点文本元素"这回事（网页正文、PDF、Electron 的自绘编辑器、微信聊天记录），
    /// 我们既不知道它是什么、也没法确认 ⌘V 会落在哪里——那就不往它身上粘。
    static func readSelectedTextWithClipboardFallback(completion: @escaping (Selection?) -> Void) {
        if let selection = readSelection() {
            DispatchQueue.main.async { completion(selection) }
            return
        }
        guard Permissions.isAccessibilityTrusted else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let pb = NSPasteboard.general
        // 全 flavour 快照：用户的剪贴板里可能是图片/文件/RTF，只存 `.string` 再写回
        // 等于把这些 flavour 抹掉（oldString 还会是 nil，剪贴板直接归零）。
        let snapshot = ClipboardSnapshot.capture(pb)
        let oldCount = snapshot.changeCount
        Log.info("Selection fallback snapshot \(snapshot.logSummary)")

        // 剪贴板大到快照整份放弃了：这时候再发 ⌘C，等于拿选区把它顶掉且永远还不回来。
        // 宁可让这次指令降级成"没选区"，也不毁掉用户剪贴板里的那份东西。
        guard !snapshot.isOversize else {
            Log.warn("Selection fallback skipped: clipboard too large to snapshot")
            DispatchQueue.main.async { completion(nil) }
            return
        }

        sendCmdC()
        // 不再固定等 0.35s 只看一眼：复制早落地就早回（常见情况比旧实现更快），晚落地也有人收拾。
        DispatchQueue.main.asyncAfter(deadline: .now() + copyPollInterval) {
            pollAfterCopy(pb: pb, snapshot: snapshot, oldCount: oldCount,
                          elapsed: copyPollInterval, completion: completion)
        }
    }

    /// ⌘C 之后的两段式等待（每 50ms 一次，全程主线程）：
    /// - 复制落地（changeCount 跳了）→ 取文本 + 原样恢复快照 + 通知插入会话，回调结果；
    /// - 到 0.35s 还没落地 → 先按"读不到选区"回调降级，绝不让指令干等，
    ///   但**继续看守到 1.5s**：⌘C 已经发出去了，目标应用那一刻卡住的话它会晚一步落地。
    ///   没人看守的话，晚到的选区文本会把用户的原剪贴板永久顶掉，而且 TextInserter 那边
    ///   待恢复的任务还会因为 changeCount 对不上而判成"用户复制了新东西"一起放弃。
    private static func pollAfterCopy(pb: NSPasteboard, snapshot: ClipboardSnapshot,
                                      oldCount: Int, elapsed: Double,
                                      completion: ((Selection?) -> Void)?) {
        var pending = completion

        if pb.changeCount != oldCount {
            let late = pending == nil
            // 迟到的复制：结果已经用不上了（调用方早按"没选区"走了），但剪贴板必须还回去。
            // 唯一不该插手的情况是此刻躺着的正是 MicType 自己写进去、还等着 ⌘V 的那段文字——
            // 那一份归 TextInserter 的恢复会话管，这里动它会把用户要粘的内容换掉。
            if late && TextInserter.clipboardIsOurs {
                Log.warn("Selection fallback: late copy landed on our own paste — leaving it to the insert session")
                return
            }
            var result: Selection? = nil
            if let copied = pb.string(forType: .string),
               !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 兜底拿到的选区一律不可编辑（见 readSelectedTextWithClipboardFallback 的注释）
                result = Selection(text: copied, editable: false)
            }
            // 恢复原剪贴板，不留痕迹
            let after = snapshot.restore(to: pb)
            // 内容原样写回了，但 changeCount 必然跳一格；不告诉插入会话的话，
            // 它待恢复的任务会误判成"用户复制了新东西"而放弃，用户的原剪贴板就此丢失。
            TextInserter.clipboardRewritten(previousChangeCount: oldCount, newChangeCount: after)
            Log.info("Selection fallback restored items=\(snapshot.itemCount) types=\(snapshot.typeCount)"
                     + " wait=\(Int(elapsed * 1000))ms" + (late ? " (late copy, result dropped)" : ""))
            pending?(result)
            return
        }

        if let done = pending, elapsed >= copyDecideSeconds {
            // 先降级回调，但不收工：⌘C 还可能在路上
            Log.info("Selection fallback: no copy within \(Int(copyDecideSeconds * 1000))ms"
                     + " — degrading to no-selection, still watching")
            pending = nil
            done(nil)
        }

        guard elapsed + copyPollInterval <= copyWatchSeconds else {
            Log.info("Selection fallback: clipboard untouched (no copy happened)")
            pending?(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + copyPollInterval) {
            pollAfterCopy(pb: pb, snapshot: snapshot, oldCount: oldCount,
                          elapsed: elapsed + copyPollInterval, completion: pending)
        }
    }

    private static func sendCmdC() {
        let source = CGEventSource(stateID: .hidSystemState)
        // 8 = kVK_ANSI_C
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
