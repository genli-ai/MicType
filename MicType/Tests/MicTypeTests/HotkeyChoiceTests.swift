import XCTest
@testable import MicType

/// 热键修饰位的纯函数层单测。按下/松开沿一旦判错，录音就会停不下来
/// （另一侧同名修饰键还按着时，合并位 .option 仍然是 1），所以这几条位定义要钉死。
final class HotkeyChoiceTests: XCTestCase {

    /// 左右同名键必须是**不同**的设备相关位——这正是修复"松开被误判成按下"的前提
    func testLeftAndRightDeviceMasksDiffer() {
        XCTAssertNotEqual(HotkeyChoice.leftOption.deviceMask, HotkeyChoice.rightOption.deviceMask)
        XCTAssertNotEqual(HotkeyChoice.leftCommand.deviceMask, HotkeyChoice.rightCommand.deviceMask)
        XCTAssertNotEqual(HotkeyChoice.leftControl.deviceMask, HotkeyChoice.rightControl.deviceMask)
    }

    /// 设备位取自 IOLLEvent.h 的 NX_DEVICE*KEYMASK，写死在这里防止手滑改错
    func testDeviceMaskValues() {
        XCTAssertEqual(HotkeyChoice.leftControl.deviceMask, 0x0000_0001)
        XCTAssertEqual(HotkeyChoice.rightShift.deviceMask, 0x0000_0004)
        XCTAssertEqual(HotkeyChoice.leftCommand.deviceMask, 0x0000_0008)
        XCTAssertEqual(HotkeyChoice.rightCommand.deviceMask, 0x0000_0010)
        XCTAssertEqual(HotkeyChoice.leftOption.deviceMask, 0x0000_0020)
        XCTAssertEqual(HotkeyChoice.rightOption.deviceMask, 0x0000_0040)
        XCTAssertEqual(HotkeyChoice.rightControl.deviceMask, 0x0000_2000)
    }

    /// 每一颗键自己的位必须落在"同名左右两位"里，否则 deviceMaskPair 那道
    /// "这条事件报不报设备位"的判断会永远不成立，退回合并位 = 修了个寂寞
    func testDeviceMaskIsContainedInItsPair() {
        for choice in HotkeyChoice.allCases where choice.deviceMask != 0 {
            XCTAssertEqual(choice.deviceMask & choice.deviceMaskPair, choice.deviceMask,
                           "\(choice.rawValue) 的设备位不在它的左右对里")
        }
    }

    /// Fn 没有设备相关位，也没有"另一侧"：必须返回 0，好让状态机退回合并位判断
    func testFnHasNoDeviceBits() {
        XCTAssertEqual(HotkeyChoice.fn.deviceMask, 0)
        XCTAssertEqual(HotkeyChoice.fn.deviceMaskPair, 0)
        XCTAssertEqual(HotkeyChoice.fn.flagMask, 1 << 23)
    }

    /// 左右同名键共用一个合并位、但键码必须各不相同（"只认右侧那颗"是真的）
    func testKeyCodesAreUnique() {
        let codes = HotkeyChoice.allCases.map { $0.keyCode }
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertEqual(HotkeyChoice.leftOption.flagMask, HotkeyChoice.rightOption.flagMask)
    }

    // MARK: - 只有一颗键 / 名字

    /// 界面上只剩右 Option 一个选择（用户 2026-09-20 拍板）：不管 UserDefaults 里存着什么，
    /// 读出来的都是它。设置页、引导、菜单栏念的都是这一条，念错就是让用户按一颗不工作的键。
    func testHotkeyIsAlwaysRightOption() {
        let stored = UserDefaults.standard.string(forKey: SettingsKeys.hotkey)
        defer { UserDefaults.standard.set(stored, forKey: SettingsKeys.hotkey) }

        for raw in ["leftCommand", "fn", "rightControl", "garbage", ""] {
            UserDefaults.standard.set(raw, forKey: SettingsKeys.hotkey)
            XCTAssertEqual(Settings.shared.hotkey, .rightOption, raw)
        }
    }

    /// 枚举本身**不许被砍到只剩一个 case**：HotkeyManager 整层按 HotkeyChoice 的位定义工作，
    /// 而老设置 / 老备份文件里存着别的值，读进来时仍要有 case 认得它
    func testEnumKeepsEveryCaseEvenThoughOnlyOneIsUsed() {
        XCTAssertEqual(HotkeyChoice.allCases.count, 8)
        XCTAssertEqual(HotkeyChoice(rawValue: "leftCommand"), .leftCommand)
        XCTAssertEqual(HotkeyChoice(rawValue: "fn"), .fn)
    }

    /// 键名一律写全（「右 Option」/「Right Option」），**不许出现 R⌥ 这种缩写**：
    /// 菜单栏第一行和引导里的每一句话都用它，用户得能照着念出来
    func testNamesAreSpelledOutNotAbbreviated() {
        let saved = L10n.shared.language
        defer { L10n.shared.language = saved }

        L10n.shared.language = .zh
        XCTAssertEqual(HotkeyChoice.rightOption.plainName, "右 Option")
        XCTAssertEqual(HotkeyChoice.rightOption.displayName, "右 Option (⌥)")
        L10n.shared.language = .en
        XCTAssertEqual(HotkeyChoice.rightOption.plainName, "Right Option")
        XCTAssertEqual(HotkeyChoice.rightCommand.displayName, "Right Command (⌘)")

        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            for choice in HotkeyChoice.allCases {
                let name = choice.plainName
                XCTAssertFalse(name.isEmpty, choice.rawValue)
                // 缩写的特征就是"只有一两个字符 + 一个符号"：全名一定比它长
                XCTAssertGreaterThan(name.count, 3, name)
                for abbreviation in ["R⌥", "R⌘", "R⌃", "L⌥", "L⌘", "L⌃", "右⌥", "左⌥"] {
                    XCTAssertFalse(name.contains(abbreviation), name)
                }
                // 全名是 displayName 去掉括号里的符号那一段：两处不能各写各的
                XCTAssertTrue(choice.displayName.hasPrefix(name), choice.displayName)
            }
        }
    }
}
