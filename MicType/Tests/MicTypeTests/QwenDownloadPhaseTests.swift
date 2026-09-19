import XCTest
@testable import MicType

/// 模型下载状态的纯函数层单测。
/// 重点不是"文案写得对不对"，而是 **statusText 不是快照**：同一个 phase 在中文 / 英文界面下
/// 各渲染一次，必须给出各自语言的文字——以前下载器直接存一句拼好的话，下载进行中切语言
/// 就会一直挂着旧语言那句（CLAUDE.md「i18n 快照字符串」那个老坑）。
final class QwenDownloadPhaseTests: XCTestCase {

    private var savedLanguage: AppLanguage = .zh

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    private func text(_ phase: QwenDownloadPhase, _ language: AppLanguage) -> String {
        L10n.shared.language = language
        return phase.statusText
    }

    // MARK: 语言中性：同一个值，两种语言各渲染一次

    func testStatusTextFollowsCurrentLanguage() {
        let phase = QwenDownloadPhase.fetchingList
        XCTAssertEqual(text(phase, .zh), "正在获取文件清单…")
        XCTAssertEqual(text(phase, .en), "Fetching file list…")
        // 再切回去还得是中文——渲染必须每次现算，不能记住第一次的结果
        XCTAssertEqual(text(phase, .zh), "正在获取文件清单…")
    }

    func testIdleRendersEmptyInBothLanguages() {
        XCTAssertEqual(text(.idle, .zh), "")
        XCTAssertEqual(text(.idle, .en), "")
    }

    func testCancelledAndCompleted() {
        XCTAssertEqual(text(.cancelled, .zh), "已取消")
        XCTAssertEqual(text(.cancelled, .en), "Cancelled")
        XCTAssertEqual(text(.completed(fileCount: 12), .zh), "下载完成 ✓（12 个文件）")
        XCTAssertEqual(text(.completed(fileCount: 12), .en), "Download complete ✓ (12 files)")
    }

    // MARK: 计数与字节数

    func testStartingFileShowsOneBasedIndexAndPath() {
        let phase = QwenDownloadPhase.startingFile(fileIndex: 0, fileCount: 7, file: "model.safetensors")
        XCTAssertEqual(text(phase, .zh), "下载中 (1/7): model.safetensors")
        XCTAssertEqual(text(phase, .en), "Downloading (1/7): model.safetensors")
    }

    func testDownloadingFormatsMegabytes() {
        let phase = QwenDownloadPhase.downloading(fileIndex: 2, fileCount: 7,
                                                  doneBytes: 100 * 1_048_576,
                                                  totalBytes: 860 * 1_048_576)
        XCTAssertEqual(text(phase, .zh), "下载中 (3/7) 100 / 860 MB")
        XCTAssertEqual(text(phase, .en), "Downloading (3/7) 100 / 860 MB")
    }

    func testMegabytesConversion() {
        XCTAssertEqual(QwenDownloadPhase.megabytes(1_048_576), 1, accuracy: 0.0001)
        XCTAssertEqual(QwenDownloadPhase.megabytes(0), 0, accuracy: 0.0001)
        XCTAssertEqual(QwenDownloadPhase.megabytes(524_288), 0.5, accuracy: 0.0001)
    }

    // MARK: 失败原因

    func testFailureTextsAreLocalised() {
        XCTAssertEqual(text(.failed(.emptyRepo), .zh), "失败：模型仓库为空或清单格式异常")
        XCTAssertEqual(text(.failed(.emptyRepo), .en),
                       "Failed: Model repo is empty or the manifest is malformed")
        XCTAssertTrue(text(.failed(.fileListUnavailable), .en).hasPrefix("Failed: "))
        XCTAssertTrue(text(.failed(.allMirrorsFailed), .zh).hasPrefix("失败："))
    }

    func testSaveFailureKeepsSystemDetail() {
        // 系统原文（语言由 macOS 决定）只当细节附在后面，前面那句永远跟界面语言
        let phase = QwenDownloadPhase.failed(.saveFailed(detail: "No such file or directory"))
        XCTAssertEqual(text(phase, .zh), "失败：保存失败：No such file or directory")
        XCTAssertEqual(text(phase, .en), "Failed: Save failed: No such file or directory")
    }

    func testPhaseIsEquatable() {
        XCTAssertEqual(QwenDownloadPhase.completed(fileCount: 3), .completed(fileCount: 3))
        XCTAssertNotEqual(QwenDownloadPhase.completed(fileCount: 3), .completed(fileCount: 4))
        XCTAssertNotEqual(QwenDownloadPhase.failed(.emptyRepo), .failed(.allMirrorsFailed))
    }
}
