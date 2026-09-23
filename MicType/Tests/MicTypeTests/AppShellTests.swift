import XCTest
import AppKit
@testable import MicType

/// 那几样"App 外壳"的东西：主菜单（⌘C / ⌘V 的来路）、菜单栏图标、启动时闪哪一句。
/// 它们的共同点是**出了错编译器一个字都不会说**，而用户第一眼就会撞上。
///
/// 4.3.5 删掉了「Dock 图标的计数」那一组（WindowPresence）：MicType 从此是普通应用，
/// Dock 图标一直都在，没有什么需要被计数了（用户 2026-09-22 拍板）。
final class AppShellTests: XCTestCase {

    private var savedLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    /// 英文界面里不许出现汉字 / 全角标点（与别处同一条尺子）
    private func containsCJKOrFullWidth(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3000...0x303F).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xFF00...0xFFEF).contains(scalar.value)
        }
    }

    // MARK: - 主菜单

    private func editMenu() -> NSMenu {
        let main = AppMenu.build()
        // 第一个是 App 菜单（系统按应用名显示），第二个才是「编辑」
        guard main.items.count >= 2, let edit = main.items[1].submenu else {
            XCTFail("主菜单里没有「编辑」")
            return NSMenu()
        }
        return edit
    }

    /// 六把快捷键一把都不能少：少一把就是少一样用户天天要用的功能。
    /// 4.3.4 之前整份主菜单根本不存在，于是自家窗口里这六把全是死的
    func testEditMenuCarriesAllSixShortcuts() {
        let items = editMenu().items.filter { !$0.isSeparatorItem }
        for shortcut in AppMenu.editShortcuts {
            let found = items.contains { item in
                item.keyEquivalent == shortcut.key
                    && item.keyEquivalentModifierMask == shortcut.modifiers
            }
            XCTAssertTrue(found, "「编辑」菜单里缺 \(shortcut.modifiers)+\(shortcut.key)")
        }
    }

    /// 粘贴 / 复制 / 全选必须挂在**标准选择器**上：换成自己写的动作，
    /// 输入框就收不到了（AppKit 的文本控件只认这几个名字）
    func testEditMenuUsesTheStandardSelectors() {
        let actions = editMenu().items.compactMap { $0.action }
        for selector in [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)),
                         #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)),
                         Selector(("undo:")), Selector(("redo:"))] {
            XCTAssertTrue(actions.contains(selector), "缺选择器 \(selector)")
        }
    }

    /// 每一项都 `target = nil`：写死 target 的话，粘贴会被送到一个固定的对象，
    /// 而它多半不是用户此刻在打字的那个框
    func testEditMenuItemsGoThroughTheResponderChain() {
        for item in editMenu().items where !item.isSeparatorItem {
            XCTAssertNil(item.target, item.title)
        }
    }

    /// App 菜单那四项（关于 / 设置… / 检查更新… / 退出）都得有动作，⌘, 和 ⌘Q 都在。
    /// 「检查更新…」5.0.1 补进来：菜单栏那份菜单只剩三项，这两处必须说同一件事
    func testAppMenuHasAboutSettingsUpdateAndQuit() {
        guard let app = AppMenu.build().items.first?.submenu else {
            return XCTFail("没有 App 菜单")
        }
        let items = app.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.count, 4)
        for item in items { XCTAssertNotNil(item.action, item.title) }
        XCTAssertTrue(items.contains { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        XCTAssertTrue(items.contains { $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == .command })
    }

    /// 菜单标题两种语言都得有（漏 tr() 的典型表现是两侧拿到同一串）
    func testMenuTitlesAreBilingual() {
        L10n.shared.language = .zh
        let zh = AppMenu.build().items.compactMap { $0.submenu?.items.map(\.title) }.flatMap { $0 }
        L10n.shared.language = .en
        let en = AppMenu.build().items.compactMap { $0.submenu?.items.map(\.title) }.flatMap { $0 }
        XCTAssertEqual(zh.count, en.count)
        for title in en where !title.isEmpty {
            XCTAssertFalse(containsCJKOrFullWidth(title), title)
        }
        XCTAssertNotEqual(zh, en)
    }

    // MARK: - 菜单栏图标

    /// 三态都得画得出来，尺寸对得上，空闲那张是模板图
    ///（模板图才会在浅色 / 深色菜单栏、以及被点开时自动反色）
    func testMenuBarIconStates() {
        let idle = MenuBarIcon.image(.idle)
        XCTAssertEqual(idle.size.width, MenuBarIcon.menuBarSize)
        XCTAssertEqual(idle.size.height, MenuBarIcon.menuBarSize)
        XCTAssertTrue(idle.isTemplate)

        let recording = MenuBarIcon.image(.recording)
        XCTAssertEqual(recording.size.width, MenuBarIcon.menuBarSize)
        // 录音态不变色（4.3.5）：同一枚模板剪影，只有旁白不同
        XCTAssertTrue(recording.isTemplate, "录音态不变色：系统的橙点已经在说麦克风在用")

        let processing = MenuBarIcon.image(.processing)
        XCTAssertGreaterThan(processing.size.width, 0)

        let large = MenuBarIcon.large()
        XCTAssertEqual(large.size.width, MenuBarIcon.largeSize)
        XCTAssertTrue(large.isTemplate)
    }

    /// 真的画出了东西。几何算错（比如半径变成 0、标志被挤出画布）时图还是"有效的 NSImage"，
    /// 只是**全透明**——菜单栏上那一格会变成空白，而没有任何测试会红
    func testMenuBarIconActuallyDrawsInk() {
        for size in [MenuBarIcon.menuBarSize, MenuBarIcon.largeSize] {
            let pixels = Int(size) * 2
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: pixels, pixelsHigh: pixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else {
                return XCTFail("建不出位图")
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            MenuBarIcon.mark(size: size, color: .black)
                .draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()

            var inked = 0
            for x in stride(from: 0, to: pixels, by: 2) {
                for y in stride(from: 0, to: pixels, by: 2) {
                    if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 }
                }
            }
            // 采样点的 5%~60%：低于下限说明什么都没画出来，高于上限说明糊成了一整块
            let sampled = (pixels / 2) * (pixels / 2)
            XCTAssertGreaterThan(inked, sampled / 20, "size=\(size) 几乎什么都没画")
            XCTAssertLessThan(inked, sampled * 3 / 5, "size=\(size) 糊成一整块")
        }
    }

    // MARK: - 启动时闪哪一句

    /// 三种情况各一条：引导要弹 → 一个字都不闪（引导自己就是说明书）；
    /// 刚升完级 → 版本号那一句；平常启动 → "它已经在运行了"
    func testLaunchNoticePicksOneOfThreeOutcomes() {
        XCTAssertEqual(LaunchNotice.decide(updatedTo: nil, onboardingShowing: true), .none)
        XCTAssertEqual(LaunchNotice.decide(updatedTo: "4.3.4", onboardingShowing: true), .none)
        XCTAssertEqual(LaunchNotice.decide(updatedTo: "4.3.4", onboardingShowing: false),
                       .updated(version: "4.3.4"))
        XCTAssertEqual(LaunchNotice.decide(updatedTo: nil, onboardingShowing: false), .running)
        // 条子上是个空串（脚本写坏了）不算升级过
        XCTAssertEqual(LaunchNotice.decide(updatedTo: "  ", onboardingShowing: false), .running)
    }

    /// 闪的内容：不闪那一档没有文字；另外两档都要点名**按哪颗键**
    ///（这句提示的全部用意就是"它在哪 + 下一步按什么"），升级那一档还要带版本号
    func testLaunchNoticeCopySaysWhereItIsAndWhatToPress() {
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            XCTAssertNil(LaunchNotice.copy(for: .none))
            let key = HotkeyChoice.rightOption.displayName

            guard let running = LaunchNotice.copy(for: .running) else {
                return XCTFail("平常启动那一句不能是空的")
            }
            XCTAssertTrue(running.contains(key), running)
            XCTAssertFalse(running.contains("\n"), running)

            guard let updated = LaunchNotice.copy(for: .updated(version: "4.3.4")) else {
                return XCTFail("升级那一句不能是空的")
            }
            XCTAssertTrue(updated.contains("4.3.4"), updated)
            XCTAssertTrue(updated.contains(key), updated)
            XCTAssertNotEqual(running, updated)

            if language == .en {
                XCTAssertFalse(containsCJKOrFullWidth(running), running)
                XCTAssertFalse(containsCJKOrFullWidth(updated), updated)
            }
        }
    }

    /// 中英两侧不能是同一串（漏写一侧的典型表现）
    func testLaunchNoticeCopyIsBilingual() {
        L10n.shared.language = .zh
        let zh = LaunchNotice.copy(for: .running)
        L10n.shared.language = .en
        XCTAssertNotEqual(zh, LaunchNotice.copy(for: .running))
    }
}
