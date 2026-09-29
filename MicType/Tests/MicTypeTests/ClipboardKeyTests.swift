import XCTest
@testable import MicType

/// 引导 ② 从剪贴板认 Key 的那条纯函数（ClipboardKey.candidate）。
///
/// 判据故意窄：认错一次 = 把用户剪贴板里的别的东西当成 Key 发给 OpenAI 去验。
/// 所以这里钉的是三件事：前缀、长度、首尾空白去掉但中间不许有空白。
final class ClipboardKeyTests: XCTestCase {

    private let realistic = "sk-proj-" + String(repeating: "Ab3_", count: 20)

    /// 以 sk- 开头、够长、只有字母数字与 - _ → 认
    func testAcceptsAKeyShapedString() {
        XCTAssertEqual(ClipboardKey.candidate(from: realistic), realistic)
        XCTAssertEqual(ClipboardKey.candidate(from: "sk-" + String(repeating: "a", count: 17)),
                       "sk-" + String(repeating: "a", count: 17), "正好 20 个字符是下限")
    }

    /// 前缀不对 / 空 / nil → 不认
    func testRejectsTheWrongPrefix() {
        XCTAssertNil(ClipboardKey.candidate(from: nil))
        XCTAssertNil(ClipboardKey.candidate(from: ""))
        XCTAssertNil(ClipboardKey.candidate(from: "pk-" + String(repeating: "a", count: 40)))
        XCTAssertNil(ClipboardKey.candidate(from: "SK-" + String(repeating: "a", count: 40)),
                     "大写的 SK- 不是 OpenAI 的 Key")
        XCTAssertNil(ClipboardKey.candidate(from: "我的 key 是 " + realistic), "前缀必须在最前面")
    }

    /// 太短（sk- 加几个字的笔记）或长得离谱 → 不认
    func testRejectsTheWrongLength() {
        XCTAssertNil(ClipboardKey.candidate(from: "sk-" + String(repeating: "a", count: 16)), "19 个字符")
        XCTAssertNil(ClipboardKey.candidate(from: "sk-short"))
        XCTAssertNil(ClipboardKey.candidate(from: "sk-" + String(repeating: "a", count: 600)))
    }

    /// 首尾的空白与换行去掉（从网页上复制常带一个换行）；**中间**有空白就是一段话，不认
    func testTrimsTheEdgesButRejectsInnerWhitespace() {
        XCTAssertEqual(ClipboardKey.candidate(from: "  \n" + realistic + "\n "), realistic)
        XCTAssertNil(ClipboardKey.candidate(from: "sk-abc def ghi jkl mno pqr stu"))
        XCTAssertNil(ClipboardKey.candidate(from: realistic + "\nsecond line"))
    }

    /// 字母数字与 - _ 以外的字符（中文、标点、引号）→ 不认
    func testRejectsForeignCharacters() {
        XCTAssertNil(ClipboardKey.candidate(from: "\"" + realistic + "\""))
        XCTAssertNil(ClipboardKey.candidate(from: realistic + "。"))
        XCTAssertNil(ClipboardKey.candidate(from: "sk-" + String(repeating: "钥", count: 30)))
    }
}
