import AppKit

/// 落进 **MicType 自己窗口**的那条路：不写剪贴板、不发合成 ⌘V，
/// 直接写进 key window 的 first responder。
///
/// 为什么非要单开一条（4.1.5 用户实测，docs/TODO 待修 bug 3）：
/// 设置 → 云端 AI → 点进「自定义规则」说一句，日志一路绿灯
/// （`Deliver start … route=inserter` → `Insert target=com.ligen.mictype path=fast outcome=pasted`），
/// 框里一个字都没有。查下来根因在 AppKit 的按键分发规则上，**不是焦点抖动**：
///
///   • ⌘V 在 Cocoa 里只是 **Edit 菜单里 Paste 那一项的 key equivalent**——
///     NSTextView / 字段编辑器自己不认 ⌘V，是菜单把它翻译成 `paste:` 发给响应链的；
///   • 而 MicType 是菜单栏应用（Info.plist `LSUIElement` + `setActivationPolicy(.accessory)`），
///     全工程只建过状态栏那一个 NSMenu，**从没装过带 Edit 的主菜单**，
///     也就没有 Paste 这一项：这一下 ⌘V 谁都不接，被直接丢掉；
///   • 实测（同样没装 Edit 菜单的进程里，把 ⌘V 按正常路径派发给 key window）：
///     SwiftUI 的 TextEditor 一个字都不粘；**只往主菜单里加一项 Edit → Paste，立刻就粘进去了**。
///   • 于是 `TextInserter` 那条路打向自家窗口时必然无效，而它又是无条件
///     `completion(.pasted)`、照样往日志里写 `outcome=pasted`——报了成功其实没成。
///
/// 另外两个嫌疑人已排除：悬浮窗 `OverlayPanel` 是 `.nonactivatingPanel` 且 `canBecomeKey`
/// 恒 false，抢不走 key window；`HotkeyManager` 的事件 tap 只吃 keyCode 53（Esc）、
/// 且只在录音/处理中开着，交付时早已关掉。
///
/// 纪律：**宁可说"这里没法输入"，也绝不报一次假的成功**——判不准就当没有可写的框，
/// 调用方把文字留在剪贴板并如实提示。
enum OwnWindowInserter {

    /// key window 的 first responder 能不能直接落字
    enum Target: String {
        /// 可编辑的文本视图（TextEditor / TextField 的字段编辑器）
        case editable
        /// 密码框（API Key）——**永远不往里写**
        case secure
        /// 没有可写的输入框
        case none
    }

    /// 这一段字落下去之后到底发生了什么。进日志的 `outcome=`，别随手改名。
    enum Outcome: String {
        /// 真的写进去了（回读确认过）
        case inserted
        /// 没有可写的输入框（或写了没生效）
        case noTarget = "no-target"
        /// 找到的是密码框，按纪律不写
        case secureField = "secure-field"
    }

    /// 纯判据，可单测：三个事实都由调用点从 AppKit 读出来，这里只负责怎么判。
    ///
    /// 密码框单列一档而不是并进 `.none`：那不是"没找到"，是**找到了但绝不能写**——
    /// 一段听写落进 API Key 框，用户下一步就是拿它去验证，还得自己把框清干净。
    /// 两者给用户的话也不一样。
    static func target(hasKeyWindow: Bool, isEditableTextView: Bool, isSecure: Bool) -> Target {
        // 先看有没有可写的框，再看它是不是密码框——密码框同时**也是**"可编辑的文本视图"，
        // 只判 isEditableTextView 就动手，API Key 框首当其冲
        guard hasKeyWindow, isEditableTextView else { return .none }
        return isSecure ? .secure : .editable
    }

    /// 把这段字写进自家 key window 的输入框。**只在主线程调。**
    /// 返回 `.inserted` 才算真的落了字——调用方据此决定提示什么、要不要打绿勾。
    static func insert(_ text: String) -> Outcome {
        guard Thread.isMainThread else {
            // 交付一律在主线程。万一不是，宁可当成没落字（调用方会把文字留在剪贴板）
            Log.warn("Own-window insert called off the main thread")
            return .noTarget
        }
        // 应用不在前台时 keyWindow 就是 nil——那一刻本来也没有"我们的输入框"可写。
        // NSApp 本身也要 guard：它是隐式解包的全局量，在没跑过 NSApplication.shared 的进程
        // （单测）里是 nil，直接点下去当场崩
        let window = NSApp?.keyWindow
        let textView = window?.firstResponder as? NSTextView
        switch target(hasKeyWindow: window != nil,
                      isEditableTextView: textView?.isEditable ?? false,
                      isSecure: textView.map(isSecureFieldEditor) ?? false) {
        case .none:
            return .noTarget
        case .secure:
            return .secureField
        case .editable:
            break
        }
        guard let textView = textView else { return .noTarget }

        // 走 insertText(_:replacementRange:)（NSTextInputClient 的标准入口），
        // 不直接改 string / textStorage：它内部走 shouldChangeText → didChangeText，
        // 于是撤销照样注册（⌘Z 能撤掉这一段），SwiftUI 那边也照样收到变更——
        // TextEditor 挂在 NSTextViewDelegate 的 textDidChange 上，
        // TextField / 字段编辑器则由 NSTextField 转成 controlTextDidChange。
        // 直接改 textStorage 的话字在屏幕上有、绑定里没有，关掉设置窗口就没了。
        //
        // macOS 26 实测（一个 TextEditor + TextField + SecureField 的探针窗口）：
        //   TextEditor   → first responder 是 SwiftUI.PlatformTextView（isEditable，非字段编辑器），
        //                  insertText 之后 @Published 绑定同步更新；
        //   TextField    → first responder 是 SwiftUI 的 SystemTextFieldFieldEditor
        //                  （isFieldEditor，delegate 是 AppKitTextField），绑定同样更新；
        //   SecureField  → first responder 是 NSSecureTextView（delegate 是 AppKitSecureTextField），
        //                  被下面 isSecureFieldEditor 认出来，一个字都不写。
        let range = textView.selectedRange()
        textView.insertText(text, replacementRange: range)

        // 落没落进去要**回读确认**：无条件报成功正是这次 bug 的病根。
        // 按 UTF-16 比对插入位置上的那一段，选区被替换的情况也算得准。
        let ns = textView.string as NSString
        let written = NSRange(location: range.location, length: (text as NSString).length)
        guard written.location + written.length <= ns.length,
              ns.substring(with: written) == text else {
            Log.warn("Own-window insert did not take effect")
            return .noTarget
        }
        return .inserted
    }

    /// 这是不是密码框的字段编辑器。AppKit 不给公开 API，所以三个信号叠着用：
    ///   • 类名带 Secure（NSSecureTextField 的字段编辑器是私有的 NSSecureTextView）；
    ///   • 字段编辑器的 delegate 就是被编辑的那个控件，SwiftUI 的 SecureField 背后是 NSSecureTextField；
    ///   • cell 是 NSSecureTextFieldCell（有人自己拿 NSTextField 换了 cell）。
    /// 三个都不中才当普通输入框——认不出的 first responder 在上面那一步已经被挡成 `.none` 了，
    /// 所以"没认出来就写进去"这种事不会发生。
    static func isSecureFieldEditor(_ view: NSTextView) -> Bool {
        if NSStringFromClass(type(of: view)).localizedCaseInsensitiveContains("secure") { return true }
        if let field = view.delegate as? NSTextField {
            if field is NSSecureTextField { return true }
            if field.cell is NSSecureTextFieldCell { return true }
        }
        return false
    }
}
