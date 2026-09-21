import XCTest
import AppKit
@testable import MicType

/// 往 **MicType 自己的窗口**里落字的判据（4.1.5 bug：设置 →「自定义规则」里听写，
/// 日志 `path=fast outcome=pasted`，框里一个字都没有）。
///
/// 为什么值得单测：这条路上的每一次判断失误都是**静默**的——
///   • 判松了：一段听写落进 API Key 框，用户下一步拿它去验证，还得自己清干净；
///   • 判紧了：明明框就在那儿却说"这里没法输入"；
///   • 判错了还报成功：就是 4.1.5 那个 bug 本身（无条件 `completion(.pasted)`）。
/// AppKit 那一半（真的去写 NSTextView）在单测里跑不动，所以判据被抽成纯函数放在这里。
final class OwnWindowInsertTests: XCTestCase {

    private func target(hasKeyWindow: Bool = true, isEditableTextView: Bool = true,
                        isSecure: Bool = false) -> OwnWindowInserter.Target {
        OwnWindowInserter.target(hasKeyWindow: hasKeyWindow,
                                 isEditableTextView: isEditableTextView, isSecure: isSecure)
    }

    // MARK: - 判据

    /// 光标就在一个普通可编辑文本框里（设置的「自定义规则」「词汇表」那种）→ 直接写
    func testEditableTextViewIsTheTarget() {
        XCTAssertEqual(target(), .editable)
    }

    /// 应用不在前台时 keyWindow 是 nil：那一刻没有"我们的输入框"可写，如实说没有
    func testNoKeyWindowMeansNoTarget() {
        XCTAssertEqual(target(hasKeyWindow: false), .none)
        // 就算 first responder 那两位看上去还合适，也不许凭它落字
        XCTAssertEqual(target(hasKeyWindow: false, isEditableTextView: true), .none)
    }

    /// first responder 不是可编辑文本视图（按钮、列表、只读文本…）→ 没有可写的框。
    /// 认不出来的 responder 也走这一档：**默认拒绝**，绝不往看不懂的东西里写
    func testNonEditableResponderMeansNoTarget() {
        XCTAssertEqual(target(isEditableTextView: false), .none)
    }

    /// **密码框永远不写**（云端 AI 那一页的 API Key 是 SecureField）。
    /// 它同时也是"可编辑的文本视图"，判据的顺序错一点就会写进去
    func testSecureFieldIsRefusedEvenThoughItIsEditable() {
        XCTAssertEqual(target(isEditableTextView: true, isSecure: true), .secure)
        XCTAssertNotEqual(target(isEditableTextView: true, isSecure: true), .editable)
    }

    /// 密码框单列一档而不是并进 .none：给用户的话不一样
    /// （「密码框里不能听写」vs「这里没有可以输入文字的框」）
    func testSecureIsItsOwnCaseSoTheMessageCanDiffer() {
        XCTAssertNotEqual(OwnWindowInserter.Target.secure, .none)
    }

    // MARK: - 密码框的识别

    /// 普通 NSTextView 不是密码框
    func testPlainTextViewIsNotSecure() {
        XCTAssertFalse(OwnWindowInserter.isSecureFieldEditor(NSTextView()))
    }

    /// 真实场景里密码框的字段编辑器是私有的 NSSecureTextView——公开 API 认不出来，
    /// 只能看类名。这里用一个同样带 Secure 的子类钉住这条判据
    func testSecureLookingFieldEditorIsRefused() {
        XCTAssertTrue(OwnWindowInserter.isSecureFieldEditor(FakeSecureTextView()))
    }

    // MARK: - 结果名（进日志的 outcome=）

    func testOutcomeNamesAreStableForLogs() {
        XCTAssertEqual(OwnWindowInserter.Outcome.inserted.rawValue, "inserted")
        XCTAssertEqual(OwnWindowInserter.Outcome.noTarget.rawValue, "no-target")
        XCTAssertEqual(OwnWindowInserter.Outcome.secureField.rawValue, "secure-field")
    }

    /// 没有 key window（测试进程里从来没有）时**绝不报成功**：
    /// 调用方据此把文字留在剪贴板并如实提示，而不是打一个假绿勾
    func testInsertNeverClaimsSuccessWithoutAWindow() {
        XCTAssertNotEqual(OwnWindowInserter.insert("你好"), .inserted)
    }
}

/// 名字里带 Secure 的文本视图（AppKit 真正用的是私有的 NSSecureTextView）
private final class FakeSecureTextView: NSTextView {}
