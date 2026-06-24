import AppKit

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
        let oldString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 给剪贴板写入留一点时间，再发送 ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.pasteDelay) {
            sendCmdV(keyHold: timing.keyHold) {
                completion?()
            }
            if allowRestore && Settings.shared.restoreClipboard {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    // 只有当剪贴板还是我们写入的内容时才恢复，避免覆盖用户新复制的东西
                    if pasteboard.string(forType: .string) == text {
                        pasteboard.clearContents()
                        if let old = oldString {
                            pasteboard.setString(old, forType: .string)
                        }
                    }
                }
            }
        }
    }

    private static func sendCmdV(keyHold: Double = 0.03, completion: (() -> Void)? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        // 9 = kVK_ANSI_V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
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
