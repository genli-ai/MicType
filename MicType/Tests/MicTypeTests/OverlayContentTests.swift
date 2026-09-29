import XCTest
@testable import MicType

/// 悬浮窗形态里的纯函数：「落」那一行写什么、错误给哪颗按钮、字数怎么数、波形怎么动。
/// 这些都是用户每次听写都看得见的东西，判错了不会崩，只会悄悄说错话——所以钉死。
final class OverlayContentTests: XCTestCase {

    private var savedLanguage: AppLanguage = .zh

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: - 「落」那一行

    /// 润色改了字：原文前 8 字… → 润色前 8 字…（设计稿那一句）
    func testDiffWhenPolishChangedWords() {
        let body = OverlayDoneLine.make(raw: "那个我明天下午三点开会嗯", final: "明天下午三点开会。")
        XCTAssertEqual(body, .diff(from: "那个我明天下午三…", to: "明天下午三点开会…"))
    }

    /// 只差标点 / 空格：不算改了字，只给成稿前 16 字（箭头两边一模一样只会让人困惑）
    func testPunctuationOnlyChangeIsPlain() {
        let body = OverlayDoneLine.make(raw: "明天下午三点开会", final: "明天下午三点开会。")
        XCTAssertEqual(body, .text("明天下午三点开会。"))
    }

    /// 没改字、成稿很长：截到 16 字补「…」；换行压成空格
    func testPlainTruncatesAtSixteen() {
        let text = "一二三四五六七八九十一二三四五六七八"
        XCTAssertEqual(OverlayDoneLine.make(raw: text, final: text), .text("一二三四五六七八九十一二三四五六…"))
        XCTAssertEqual(OverlayDoneLine.prefix("第一行\n\n第二行", 16), "第一行 第二行")
    }

    /// 大小写改动算改了字（"hello" → "Hello" 是润色做的事）
    func testCaseChangeCountsAsChange() {
        if case .text = OverlayDoneLine.make(raw: "hello world", final: "Hello world.") {
            XCTFail("大小写变化应当给「原文 → 润色」")
        }
    }

    // MARK: - 错误按钮

    func testErrorButtonForKeyProblems() {
        XCTAssertEqual(OverlayErrorAction.classify("API Key 无效或已失效 (401)，请检查是否粘贴完整"), .openSettings)
        XCTAssertEqual(OverlayErrorAction.classify("Invalid or revoked API key (401) — check it"), .openSettings)
        L10n.shared.language = .zh
        XCTAssertEqual(OverlayErrorAction.classify(RecognitionEngineReadiness.cloudKeyMissing(.openai).message),
                       .openSettings)
        L10n.shared.language = .en
        XCTAssertEqual(OverlayErrorAction.classify(RecognitionEngineReadiness.cloudKeyMissing(.openai).message),
                       .openSettings)
    }

    /// 网络 / 超时 / 没听到：设置里修不了，给「关闭」（本版没有重试入口）
    func testErrorButtonForEverythingElseIsClose() {
        L10n.shared.language = .zh
        XCTAssertEqual(OverlayErrorAction.classify(LLMCatalog.timeoutCopy().text), .dismiss)
        XCTAssertEqual(OverlayErrorAction.classify(RecognitionEngineReadiness.offline.message), .dismiss)
        XCTAssertEqual(OverlayErrorAction.classify("没有听到内容"), .dismiss)
        XCTAssertEqual(OverlayErrorAction.dismiss.label, "关闭")
        XCTAssertEqual(OverlayErrorAction.openSettings.label, "打开设置")
        L10n.shared.language = .en
        XCTAssertEqual(OverlayErrorAction.dismiss.label, "Close")
        XCTAssertEqual(OverlayErrorAction.openSettings.label, "Open Settings")
    }

    // MARK: - 字数

    func testCharacterCountIgnoresWhitespace() {
        XCTAssertEqual(OverlayCopy.countCharacters("明天 下午\n三点"), 6)
        XCTAssertEqual(OverlayCopy.countCharacters("see you"), 6)
        L10n.shared.language = .zh
        XCTAssertEqual(OverlayCopy.charCount(42), "42 字")
        L10n.shared.language = .en
        XCTAssertEqual(OverlayCopy.charCount(42), "42 chars")
    }

    // MARK: - 波形

    /// 没声音就伏下去；声音越大条越高；永远在 0–1 之内
    func testWaveformTargetsFollowLevel() {
        let phases = [0.0, 1.0, 2.0]
        let speeds = [5.0, 6.0, 7.0]
        XCTAssertEqual(WaveformModel.targets(level: 0, time: 3, phases: phases, speeds: speeds), [0, 0, 0])
        let quiet = WaveformModel.targets(level: 0.2, time: 3, phases: phases, speeds: speeds)
        let loud = WaveformModel.targets(level: 0.8, time: 3, phases: phases, speeds: speeds)
        for (q, l) in zip(quiet, loud) {
            XCTAssertLessThan(q, l)
            XCTAssertLessThanOrEqual(l, 1)
        }
        // 每根条相位不同：不会整排齐刷刷一样高
        XCTAssertGreaterThan(Set(loud).count, 1)
    }

    /// 上升快、回落慢
    func testWaveformSmoothingRisesFasterThanItFalls() {
        let up = WaveformModel.smooth(previous: 0, target: 1)
        let down = 1 - WaveformModel.smooth(previous: 1, target: 0)
        XCTAssertGreaterThan(up, down)
    }
}
