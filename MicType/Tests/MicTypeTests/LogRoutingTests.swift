import XCTest
@testable import MicType

/// 日志落在哪儿。
///
/// 为什么这条要有单测：2026-09-19 排查「测试识别 404，日志里却一行都没有」时，
/// 用户真实的 ~/Library/Logs/MicType/mictype-20260919.log 里有 210 行 CloudASR——
/// **全是单测写进去的**（CloudASRTests 用假发送器跑完整条分段流程，那些 200 响应
/// 从来没发生过）。真正的失败一行都没有，假的倒有两百行，排查直接被带偏。
/// 所以测试期间整份日志必须改写到临时目录，用户的日志只记用户真的做过的事。
final class LogRoutingTests: XCTestCase {

    func testTestsNeverWriteIntoTheUsersLogDirectory() {
        XCTAssertTrue(Log.isUnderTest, "跑在 XCTest 里就该认出来")
        let path = Log.logsDirectory.path
        let userLogs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MicType").path
        XCTAssertNotEqual(path, userLogs, "单测绝不能往用户的日志目录里写")
        XCTAssertFalse(path.hasPrefix(userLogs), "子目录也不行")
        XCTAssertTrue(path.contains("MicTypeTestLogs"), "改写到临时目录")
    }

    /// 写一行进去要真的落地在临时目录里（不然"改了路径"只是个摆设）
    func testWrittenLinesLandInTheTemporaryDirectory() {
        let marker = "LogRoutingTests marker \(UUID().uuidString)"
        Log.info(marker)
        let file = Log.todayLogFile
        let found = expectation(description: "log line flushed")
        // 日志是异步串行队列写的，轮询等它落盘（最多 2 秒）
        DispatchQueue.global().async {
            for _ in 0..<40 {
                if let text = try? String(contentsOf: file, encoding: .utf8), text.contains(marker) {
                    found.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        wait(for: [found], timeout: 3)
        XCTAssertTrue(file.path.contains("MicTypeTestLogs"))
    }
}
