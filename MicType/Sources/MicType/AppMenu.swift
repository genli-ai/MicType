import AppKit

// MARK: - 主菜单（⌘C / ⌘V 的来路）

/// MicType 从第一版起就没装过 `NSApp.mainMenu`，于是自家窗口里 **⌘C / ⌘V / ⌘A / ⌘Z / ⌘X
/// 全都无人接收**——用户只能右键粘贴。2026-09-22 的新用户反馈原话是"Key 框不能粘贴"，
/// 根因就是这个：那几个组合键不是输入框自带的功能，而是「编辑」菜单项的快捷键；
/// 没有菜单项，`NSTextField` 永远收不到 `paste:`。
///
/// （与 4.1.6「往自家窗口合成 ⌘V 无效」同一条根因：那时的 `LSUIElement` 应用没有主菜单。
/// 那一次的解法是绕开 ⌘V 自己插字（`OwnWindowInserter`），这一次是把菜单补上——
/// 两者互不影响，`OwnWindowInserter` 一行没改。）
///
/// 4.3.5 起 MicType 是普通应用，这份菜单在它成为前台时就摆在屏幕顶上，
/// 所以它还得跟着界面语言重建（见 AppDelegate.menuLanguageObserver）。
/// 4.3.4 那一版它是隐形的（菜单栏应用不显示主菜单），但键盘事件走的是同一条
/// 「窗口 → 响应链 → 主菜单」的路，快捷键那时就已经生效了。
///
/// 每一项都 `target = nil`：让 AppKit 沿响应链去找谁能办这件事——
/// 焦点在输入框里，`paste:` 就落在那个输入框上；没有输入框在前台，菜单项自己灰掉。
/// 写死 target 的话，粘贴会被送到一个固定的对象，它多半不是用户此刻在打字的那个框。
enum AppMenu {

    /// 整份主菜单。纯函数（不碰 NSApp、不读设置），所以能被单测钉住那六个快捷键。
    static func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = appSubmenu()
        main.addItem(appItem)

        let editItem = NSMenuItem()
        editItem.submenu = editSubmenu()
        main.addItem(editItem)

        return main
    }

    /// 第一个菜单（系统按应用名显示它，这里的标题只是占位）。
    /// 三项都和菜单栏那份菜单里的同名项去同一个地方，措辞也逐字相同——
    /// 同一件事在两处叫两个名字，用户会以为是两件事。
    private static func appSubmenu() -> NSMenu {
        let menu = NSMenu(title: "MicType")
        menu.addItem(item(tr("关于 MicType", "About MicType"),
                          #selector(AppDelegate.openAbout)))
        menu.addItem(.separator())
        menu.addItem(item(tr("设置…", "Settings…"), #selector(AppDelegate.openSettings),
                          key: ",", modifiers: .command))
        menu.addItem(.separator())
        menu.addItem(item(tr("退出 MicType", "Quit MicType"),
                          #selector(NSApplication.terminate(_:)),
                          key: "q", modifiers: .command))
        return menu
    }

    /// 「编辑」：这次改动真正要补的那一份。
    /// 撤销 / 重做走字符串选择器（`undo:` / `redo:` 在 Swift 里没有对应的具名方法，
    /// 它们由 `NSUndoManager` 沿响应链提供）；其余四项用标准的 `NSText` 选择器。
    private static func editSubmenu() -> NSMenu {
        let menu = NSMenu(title: tr("编辑", "Edit"))
        menu.addItem(item(tr("撤销", "Undo"), Selector(("undo:")),
                          key: "z", modifiers: .command))
        menu.addItem(item(tr("重做", "Redo"), Selector(("redo:")),
                          key: "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(tr("剪切", "Cut"), #selector(NSText.cut(_:)),
                          key: "x", modifiers: .command))
        menu.addItem(item(tr("复制", "Copy"), #selector(NSText.copy(_:)),
                          key: "c", modifiers: .command))
        menu.addItem(item(tr("粘贴", "Paste"), #selector(NSText.paste(_:)),
                          key: "v", modifiers: .command))
        menu.addItem(.separator())
        menu.addItem(item(tr("全选", "Select All"), #selector(NSText.selectAll(_:)),
                          key: "a", modifiers: .command))
        return menu
    }

    private static func item(_ title: String, _ action: Selector,
                             key: String = "",
                             modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        // 响应链自己找接收者（见文件头）
        item.target = nil
        return item
    }

    // MARK: - 单测用的判据

    /// 「编辑」菜单里必须齐的那六把快捷键。少一把就是少一样用户天天要用的功能，
    /// 而编译器对此一个字都不会说（这正是 4.3.4 之前的状态）。
    static let editShortcuts: [(key: String, modifiers: NSEvent.ModifierFlags)] = [
        ("z", .command), ("z", [.command, .shift]),
        ("x", .command), ("c", .command), ("v", .command), ("a", .command),
    ]
}
