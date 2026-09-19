import XCTest
@testable import MicType

/// 「谁的验证结论还算数」这道闸。
///
/// 为什么值得一个测试文件：这道闸决定**验证通过的 Key 会不会进钥匙串**。
/// 4.0.2 它住在 KeyEntryView 的 @StateObject 里，而设置页的路由是 `.id(nav.route)` 重建的——
/// 粘完 Key 立刻按 Esc 回概览，视图先没了，1–5 秒后回来的那个"通过"于是连钥匙串都不写、
/// 日志里也没有一行，用户看到「还没填 Key」，以为自己没粘上。
/// 所以闸门搬进了这本账本：它比任何视图都活得久，这里钉的就是它的两条规矩。
final class KeyVerificationLedgerTests: XCTestCase {

    private let ledger = KeyVerificationLedger.shared

    /// 每个用例用自己的账户名：这本账本是全进程共用的一份
    private func account(_ name: String = #function) -> String { "test." + name }

    /// 刚领到的那一代就是最新的一代——视图在不在都一样
    func testFreshGenerationIsCurrent() {
        let account = self.account()
        let generation = ledger.nextGeneration(for: account)
        XCTAssertTrue(ledger.isCurrent(generation, for: account))
    }

    /// 用户又动了输入框（再领一次）：上一趟在路上的结果一律作废，不许写钥匙串
    func testNewerGenerationRetiresTheOlderOne() {
        let account = self.account()
        let first = ledger.nextGeneration(for: account)
        let second = ledger.nextGeneration(for: account)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(ledger.isCurrent(first, for: account))
        XCTAssertTrue(ledger.isCurrent(second, for: account))
    }

    /// 一档一本账：在 OpenAI 那一档粘 Key，不该把阿里云那一档在路上的验证作废
    func testAccountsDoNotRetireEachOther() {
        let openai = account() + ".openai"
        let qwen = account() + ".qwen"
        let generation = ledger.nextGeneration(for: openai)
        _ = ledger.nextGeneration(for: qwen)
        XCTAssertTrue(ledger.isCurrent(generation, for: openai))
    }

    /// 从没验证过的那一档，任何代数都不算数（落盘要的是"这一趟是最新那一趟"的明证）
    func testUnknownAccountIsNeverCurrent() {
        XCTAssertFalse(ledger.isCurrent(1, for: account() + ".never"))
    }
}
