import XCTest
@testable import MicType

/// 英文界面里的中文残留：这是个会反复回来的问题（v4.0 调研 §4.3 一次抓到 5 处），
/// 原因也很朴素——界面字符串靠 `tr("中","English")` 行内双语，漏一个 tr()、或者在英文侧
/// 顺手写了个全角括号，编译器一声不吭，只有装着英文界面的人看得见。人眼 review 挡不住，
/// 所以把规则写成一条永久的测试：
///
/// **Sources/MicType 里的界面字面量，中文只能出现在 `tr()` 的第一个参数里。**
///
/// 扫描器是纯 Swift 状态机（不引第三方依赖），认得注释、字符串、三引号块、插值和调用栈，
/// 因此能分清"这个字面量是 tr 的第几个实参"。三类东西故意豁免：
/// 1. 三引号块——那是发给模型的 prompt，本来就该是中文；
/// 2. `Log.*` / `print` / `assert` 等调用——只进本机日志，不上界面；
/// 3. 下面两张白名单——按「文件:声明名」豁免整段非界面文本层，以及按「文件:行号」豁免
///    唯一一处故意双语的界面文案。
///
/// 加新文案时如果这个测试红了：先想想是不是真漏了 tr()，确实是"发给模型的 prompt / 文本
/// 处理规则"才往白名单里加，并且必须写清为什么。
final class CJKUIStringGuardTests: XCTestCase {

    // MARK: - 白名单

    /// 按「文件名:声明名」豁免：这些声明产出的**不是界面文字**，而是发给大模型的 prompt、
    /// 触发词表或中文标点处理规则——它们恒为中文是对的，翻成英文反而会坏事。
    /// 用声明名而不是行号：这些文件还在改，行号天天动，声明名跟着代码走。
    private static let textLayerDeclarations: Set<String> = [
        // 发给模型的 prompt 片段（词汇表提示、关于我、邮件格式硬约束、定界块、意图前缀容错）
        "AgentService.swift:vocabHint",
        "AgentService.swift:userContextHint",
        "AgentService.swift:emailFormatRequirement",
        "AgentService.swift:runOnSelection",
        "AgentService.swift:parseSelectionResult",
        "AgentService.swift:replyDraft",
        "PolishService.swift:polish",           // <<<原文>>> / <<<结束>>> 定界块
        "PolishService.swift:systemPrompt",     // 润色系统提示词的拼接段
        "QwenEngine.swift:hotwordContext",      // 送进识别模型的热词上下文
        // 文本处理规则：中文标点、分隔符、否定词、复读检测——拿来和文本比对，不显示
        "Settings.swift:listSeparators",
        "Settings.swift:parseVocabulary",
        "SkillRouter.swift:isReplyTrigger",     // 「帮我回复」这类显式触发词
        "Support.swift:boundaryClass",
        "Support.swift:punctClass",
        "Support.swift:removeFillerWords",
        "Support.swift:negationCount",
        "Support.swift:isVocabEcho",
        "Support.swift:fixMixedPunctuation",
        // 语言名本身（「中文」这一项在英文界面下也必须写成「中文」，否则选不回来）
        "Localization.swift:displayName",
        // 窗口标题：这三处已经各自按 lang 参数分支（切语言的回调里拿到的就是新语言），
        // 不是漏了 tr()
        "SettingsView.swift:show",
        "HistoryWindow.swift:show",
        "OnboardingWindow.swift:show",
    ]

    /// 按「文件名:行号」豁免的**故意例外**。加一条就写一行为什么。
    /// 行号会随着文件改动漂移——这张表故意保持极短，漂了就照测试报出来的新行号更新。
    private static let lineWhitelist: Set<String> = [
        // 界面语言选择器故意双语（"Language / 界面语言:"）：它是切回母语的唯一入口，
        // 界面已经是看不懂的那种语言时，用户也得认得出这一项。见 docs v4.0 调研 §4.3。
        "SettingsView.swift:294",
    ]

    // MARK: - 实际防线

    func testNoCJKLeaksInUIStrings() throws {
        let dir = Self.sourcesDirectory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            XCTFail("找不到源码目录 \(dir.path)——这个守卫测试必须能看到 Sources/MicType")
            return
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertGreaterThan(files.count, 10, "源码文件数明显不对，扫描器大概没找对目录")

        var failures: [String] = []
        for file in files {
            let source = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            for hit in CJKSourceScanner.scan(source) {
                if Self.lineWhitelist.contains("\(file):\(hit.line)") { continue }
                if hit.owners.contains(where: { Self.textLayerDeclarations.contains("\(file):\($0)") }) { continue }
                failures.append("\(file):\(hit.line) [\(hit.violation.rawValue)] \"\(hit.literal.prefix(60))\"")
            }
        }
        XCTAssertTrue(failures.isEmpty, """
            界面字符串里出现了中文/全角标点（应当只出现在 tr() 的第一个参数里）：
            \(failures.joined(separator: "\n"))
            —— 确实是界面文案就补 tr("中文", "English")；确实是 prompt / 文本处理规则，
            就加进 textLayerDeclarations（写清为什么）；故意双语才进 lineWhitelist。
            """)
    }

    // MARK: - 扫描器自身的单测（保证它真的会红）

    func testFlagsRawChineseLiteral() {
        let hits = CJKSourceScanner.scan(#"let label = "已保存""#)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.violation, .outsideTr)
    }

    func testAllowsChineseInFirstArgumentOfTr() {
        let hits = CJKSourceScanner.scan(#"Text(tr("已保存 ✓", "Saved"))"#)
        XCTAssertTrue(hits.isEmpty, "tr() 的中文侧是合法的")
    }

    func testFlagsChineseInSecondArgumentOfTr() {
        let hits = CJKSourceScanner.scan(#"Text(tr("界面语言", "Language / 界面语言"))"#)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.violation, .englishSide)
    }

    func testFlagsFullWidthPunctuationOnEnglishSide() {
        let hits = CJKSourceScanner.scan(#"Text(tr("模型（快）", "Model（fast）"))"#)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.violation, .englishSide)
    }

    func testAllowsEmDashAndEllipsisInEnglish() {
        // 英文侧大量使用 "—" 和 "…"，只有成对的「——」才算中文破折号
        let hits = CJKSourceScanner.scan(#"Text(tr("下载中…", "Downloading — please wait…"))"#)
        XCTAssertTrue(hits.isEmpty)
        XCTAssertTrue(CJKSourceScanner.containsFlagged("破折号——在这"))
        XCTAssertFalse(CJKSourceScanner.containsFlagged("plain — dash · dot “quoted”"))
    }

    func testIgnoresLogAndAssertCalls() {
        let source = """
        Log.info("开始录音")
        Log.warn("失败：" + reason)
        assert(ok, "不该到这里")
        print("调试")
        """
        XCTAssertTrue(CJKSourceScanner.scan(source).isEmpty)
    }

    func testIgnoresTripleQuotedPromptBlocks() {
        let source = "let prompt = \"\"\"\n你是一个语音输入润色引擎。\n只输出结果。\n\"\"\"\nlet ok = \"fine\""
        XCTAssertTrue(CJKSourceScanner.scan(source).isEmpty)
    }

    func testIgnoresComments() {
        let source = """
        // 这是中文注释，不该被判违规
        /* 块注释：同理
           第二行 */
        let ok = "fine"
        """
        XCTAssertTrue(CJKSourceScanner.scan(source).isEmpty)
    }

    func testTracksArgumentIndexAcrossNestedCalls() {
        // 第二个 tr 的英文侧混进中文，前面那个嵌套调用不能把实参序号搅乱
        let source = #"Picker(tr("标题", "Title"), selection: $x) { Text(tr("项", "Item（1）")) }"#
        let hits = CJKSourceScanner.scan(source)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.violation, .englishSide)
    }

    func testStringInterpolationDoesNotBreakParsing() {
        let source = #"let s = tr("共 \(n) 条", "\(n) items") + "。""#
        let hits = CJKSourceScanner.scan(source)
        XCTAssertEqual(hits.count, 1, "插值外面那个全角句号才是违规的那个")
        XCTAssertEqual(hits.first?.violation, .outsideTr)
    }

    func testReportsEnclosingDeclarationNames() {
        let source = """
        enum Prompts {
            static func systemPrompt() -> String {
                return "你是一个润色引擎"
            }
        }
        """
        let hits = CJKSourceScanner.scan(source)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits.first?.owners.contains("systemPrompt") ?? false,
                      "白名单按声明名豁免，扫描器必须报得出所在声明")
    }

    func testCountsLineNumbers() {
        let source = "let a = \"fine\"\n// 注释\nlet b = \"中文\"\n"
        XCTAssertEqual(CJKSourceScanner.scan(source).first?.line, 3)
    }

    private static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)            // …/MicType/Tests/MicTypeTests/本文件
            .deletingLastPathComponent()           // …/MicType/Tests/MicTypeTests
            .deletingLastPathComponent()           // …/MicType/Tests
            .deletingLastPathComponent()           // …/MicType
            .appendingPathComponent("Sources/MicType", isDirectory: true)
    }
}

// MARK: - 扫描器

/// Swift 源码的极简词法状态机：认注释、字符串、三引号块、插值和调用栈。
/// 只为回答一个问题——"这个含中文的字面量，是不是 tr() 的第一个参数"。
/// 纯函数、无副作用，可直接喂片段做单测。
enum CJKSourceScanner {

    enum Violation: String {
        case outsideTr      // 界面字面量没走 tr()
        case englishSide    // tr() 的英文侧混进了中文/全角标点
    }

    struct Hit: Equatable {
        let line: Int
        let literal: String
        let violation: Violation
        /// 由内到外的所在声明名（func / var / let / case 名），白名单按它豁免
        let owners: [String]
    }

    /// 判为「中文/全角」的字符：中日韩文字本体 + 全角标点。
    /// 故意**不**包含 "—"、"…"、"·"、弯引号——英文侧到处在用它们。
    static func isFlagged(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            let value = scalar.value
            if (0x3400...0x4DBF).contains(value) { return true }   // CJK 扩展 A
            if (0x4E00...0x9FFF).contains(value) { return true }   // CJK 基本区
            if (0xF900...0xFAFF).contains(value) { return true }   // 兼容表意文字
            if (0x3040...0x30FF).contains(value) { return true }   // 假名（顺手拦住）
            if (0xFF01...0xFF60).contains(value) { return true }   // 全角形式：，：；？！（）…
            if value == 0x3000 { return true }                     // 全角空格
            if (0x3001...0x3003).contains(value) { return true }   // 、。〃
            if (0x3008...0x3011).contains(value) { return true }   // 《》「」『』【】
            if (0x3014...0x301F).contains(value) { return true }   // 〔〕〖〗〝〞
        }
        return false
    }

    /// 单个 em dash 在英文里合法（"All mirrors failed — check your network"），
    /// 成对的「——」才是中文破折号。
    static func containsFlagged(_ text: String) -> Bool {
        if text.contains("——") { return true }
        return text.contains(where: isFlagged)
    }

    /// 这些调用里的中文与界面无关：日志只进本机日志文件，断言只给开发者看
    private static let suppressedCallees: Set<String> = [
        "Log.info", "Log.warn", "Log.error", "NSLog", "print", "debugPrint",
        "assert", "assertionFailure", "precondition", "preconditionFailure", "fatalError",
    ]

    private static let declarationKeywords: Set<String> = [
        "func", "var", "let", "case", "enum", "struct", "class", "extension", "init", "subscript",
    ]

    private struct Frame {
        let callee: String
        var argumentIndex: Int
        let isTr: Bool
        let suppressed: Bool
        /// 这一层括号/花括号所属的声明名，用于白名单豁免
        let owner: String
    }

    static func scan(_ source: String) -> [Hit] {
        var hits: [Hit] = []
        var stack: [Frame] = []
        var identifier = ""
        var previousIdentifier = ""
        var lastDeclaration = ""
        var line = 1
        let characters = Array(source)
        var index = 0

        func isIdentifierCharacter(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "."
        }

        while index < characters.count {
            let character = characters[index]

            // 标识符（含点号，"Log.info" 整体作为被调用者名）
            if isIdentifierCharacter(character) {
                identifier.append(character)
                index += 1
                continue
            }
            // 标识符到此结束：可能是个声明名，也可能是紧跟着 "(" 的被调用者
            let pendingCallee = identifier
            if !identifier.isEmpty {
                if declarationKeywords.contains(previousIdentifier) { lastDeclaration = identifier }
                previousIdentifier = identifier
                identifier = ""
            }

            if character == "\n" {
                line += 1
                index += 1
                continue
            }
            // 行注释
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            // 块注释（可嵌套）
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                var depth = 1
                index += 2
                while index < characters.count, depth > 0 {
                    if characters[index] == "\n" { line += 1 }
                    if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                        depth += 1
                        index += 2
                        continue
                    }
                    if characters[index] == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                        depth -= 1
                        index += 2
                        continue
                    }
                    index += 1
                }
                continue
            }
            // 字符串字面量
            if character == "\"" {
                let startLine = line
                let isMultiline = index + 2 < characters.count
                    && characters[index + 1] == "\"" && characters[index + 2] == "\""
                let top = stack.last
                let suppressed = top?.suppressed ?? false
                let trArgument: Int? = (top?.isTr ?? false) ? (top?.argumentIndex ?? 0) : nil
                var literal = ""

                // 插值 \( … ) 里是代码：括号配平地跳过，不计入字面量
                func skipInterpolation() {
                    var depth = 0
                    index += 1
                    repeat {
                        if characters[index] == "\n" { line += 1 }
                        if characters[index] == "(" { depth += 1 }
                        if characters[index] == ")" { depth -= 1 }
                        index += 1
                    } while index < characters.count && depth > 0
                }

                if isMultiline {
                    // 三引号块 = 发给模型的 prompt，整段豁免，只负责正确跳过
                    index += 3
                    while index < characters.count {
                        if characters[index] == "\\", index + 1 < characters.count {
                            if characters[index + 1] == "(" { skipInterpolation(); continue }
                            index += 2
                            continue
                        }
                        if characters[index] == "\"", index + 2 < characters.count,
                           characters[index + 1] == "\"", characters[index + 2] == "\"" {
                            index += 3
                            break
                        }
                        if characters[index] == "\n" { line += 1 }
                        index += 1
                    }
                    continue
                }

                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\", index + 1 < characters.count {
                        if characters[index + 1] == "(" { skipInterpolation(); continue }
                        index += 2
                        continue
                    }
                    if characters[index] == "\n" { line += 1; break }  // 未闭合：别把整个文件吞掉
                    literal.append(characters[index])
                    index += 1
                }
                if index < characters.count, characters[index] == "\"" { index += 1 }

                if !suppressed, containsFlagged(literal) {
                    let owners = (stack.map { $0.owner } + [lastDeclaration]).filter { !$0.isEmpty }
                    if trArgument == 0 {
                        // 中文侧，正常
                    } else if trArgument == 1 {
                        hits.append(Hit(line: startLine, literal: literal,
                                        violation: .englishSide, owners: owners))
                    } else {
                        hits.append(Hit(line: startLine, literal: literal,
                                        violation: .outsideTr, owners: owners))
                    }
                }
                continue
            }
            // 括号/花括号/方括号：维护调用栈
            if character == "(" || character == "[" || character == "{" {
                let callee = (character == "(") ? pendingCallee : ""
                let inheritedSuppression = stack.last?.suppressed ?? false
                stack.append(Frame(callee: callee,
                                   argumentIndex: 0,
                                   isTr: callee == "tr" || callee.hasSuffix(".tr"),
                                   suppressed: inheritedSuppression || suppressedCallees.contains(callee),
                                   owner: lastDeclaration))
                index += 1
                continue
            }
            if character == ")" || character == "]" || character == "}" {
                if !stack.isEmpty { stack.removeLast() }
                index += 1
                continue
            }
            // 逗号：当前这层的实参序号 +1（嵌套调用的逗号落在它自己那层）
            if character == "," {
                if !stack.isEmpty { stack[stack.count - 1].argumentIndex += 1 }
                index += 1
                continue
            }
            index += 1
        }
        return hits
    }
}
