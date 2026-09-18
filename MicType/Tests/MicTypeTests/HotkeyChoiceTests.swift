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
}
