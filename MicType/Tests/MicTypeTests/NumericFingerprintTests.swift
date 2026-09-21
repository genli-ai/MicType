import XCTest
@testable import MicType

/// 数字指纹（4.1.6）：让保真校验看懂「一百零一」和「101」是同一个数。
///
/// 为什么这个文件必须厚：润色从 4.1.6 起要把汉字数字改写成阿拉伯数字（提示词第 7 条），
/// 而保真校验是这条规则唯一的刹车——归一化写松一点，改错的金额 / 电话 / 日期就会直接
/// 进用户的输入框；写紧一点，每一次正确的改写都会被判成"数字被改"、整段回退，
/// 用户看到的是"这功能根本没生效"。两种错都是静默的，只能靠表格式的单测钉死。
final class NumericFingerprintTests: XCTestCase {

    /// (数字多重集, 通配多重集) 摊成排好序的字符串，方便写期望值。
    /// digitSummary 带着数字本身，**只许在测试里用**（日志纪律见它自己的注释）
    private func fingerprint(_ text: String) -> (digits: String, wildcards: String) {
        let fp = TextPostProcessor.numericFingerprint(text)
        return (TextPostProcessor.digitSummary(fp.digits), TextPostProcessor.digitSummary(fp.wildcards))
    }

    private func assertFingerprint(_ text: String, digits: String, wildcards: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        let got = fingerprint(text)
        XCTAssertEqual(got.digits, digits, "digits of 「\(text)」", file: file, line: line)
        XCTAssertEqual(got.wildcards, wildcards, "wildcards of 「\(text)」", file: file, line: line)
    }

    // MARK: - 归一化对照表

    /// 位值：有单位的汉字数字串
    func testPositionalChineseNumerals() {
        assertFingerprint("十", digits: "01")                    // 10
        assertFingerprint("十二", digits: "12")                  // 12：打头的十是 1
        assertFingerprint("二十", digits: "02")                  // 20
        assertFingerprint("一百零一", digits: "011")              // 101：念了「零」，尾数就是个位
        assertFingerprint("一百一十", digits: "011")              // 110
        assertFingerprint("一千零五十", digits: "0015")           // 1050
        assertFingerprint("七百三十二", digits: "237")            // 732
        assertFingerprint("一万二千", digits: "00012")            // 12000
        assertFingerprint("三千五百万", digits: "00000035")       // 35000000
        assertFingerprint("十万", digits: "000001")              // 100000
        assertFingerprint("一亿二千万", digits: "000000012")       // 120000000
    }

    /// 口语里**省略的尾数**：跟的是上一个单位的下一档
    func testAbbreviatedTail() {
        assertFingerprint("两千五", digits: "0025")              // 2500，不是 2005
        assertFingerprint("三百五", digits: "035")               // 350
        assertFingerprint("一万二", digits: "00012")             // 12000
    }

    /// 没单位的多字串 = 一串数位（年份、电话、房号都靠这条）
    func testDigitSequences() {
        assertFingerprint("二零一一", digits: "0112")                        // 2011
        assertFingerprint("二零一八", digits: "0128")                        // 2018
        assertFingerprint("幺三八零零幺三八零零零", digits: "00000113388")     // 13800138000
        assertFingerprint("两三", digits: "23")                              // 23：两边都这么念，不影响比较
    }

    /// 阿拉伯数字 + 汉字单位：润色最爱写的形式。用 Decimal 算，1.2 万必须正好是 12000
    func testArabicPlusChineseUnit() {
        assertFingerprint("1.2万", digits: "00012")
        assertFingerprint("3500万", digits: "00000035")
        assertFingerprint("2亿", digits: "000000002")
        assertFingerprint("1.25万", digits: "00125")           // 12500
        assertFingerprint("3000万", digits: "00000003")        // 30000000
    }

    /// 口语式的省略尾数，阿拉伯数字版：润色有时会照着人说话的样子写
    func testArabicAbbreviatedTail() {
        assertFingerprint("1万2", digits: "00012")             // 12000
        assertFingerprint("3千5", digits: "0035")              // 3500
        assertFingerprint("2百5", digits: "025")               // 250
        // 后面还跟着数字 / 单位就不是这个形状（尾数规则不适用），走别的分支。
        // **已知不支持**：「1万2千」这种混写会被拆成 10000 + 2000，和汉字的「一万二千」=12000
        // 对不上 → 回退原文（安全方向）。提示词教模型写「1.2万」，两轮实测也都是这么写的
        XCTAssertNotEqual(fingerprint("1万2千").digits, fingerprint("12000").digits)
    }

    /// 百分比、千分位、全角数字
    func testPercentAndFormatting() {
        assertFingerprint("百分之二十", digits: "02")            // 20
        assertFingerprint("百分之三十五", digits: "35")          // 35
        assertFingerprint("20%", digits: "02")
        assertFingerprint("12,000", digits: "00012")
        assertFingerprint("１２３", digits: "123")               // 全角折半角
        assertFingerprint("٢٠٢٦", digits: "0226")              // 阿拉伯-印度数字
    }

    /// **单个汉字数字、没有单位** → 不算数，只记通配：它到底是不是数只有上下文知道
    func testBareNumeralsBecomeWildcards() {
        assertFingerprint("三个人", digits: "", wildcards: "3")
        assertFingerprint("一点五", digits: "", wildcards: "15")          // 1.5
        assertFingerprint("四点一点六", digits: "", wildcards: "146")      // 版本号 4.1.6
        assertFingerprint("第一次", digits: "", wildcards: "1")
        assertFingerprint("十二块五", digits: "12", wildcards: "5")        // 12 + 通配 5
        assertFingerprint("三点半", digits: "", wildcards: "3")           // 「半」保持汉字
    }

    /// 含数字字、却根本不表数量的固定说法：比之前整个摘掉
    func testIdiomsAreNotNumbers() {
        for idiom in ["万一", "一下", "一起", "一些", "一样", "一共", "统一", "唯一",
                      "三心二意", "乱七八糟", "五花八门", "十全十美", "独一无二",
                      "千方百计", "百分百", "一点点", "有一点"] {
            assertFingerprint(idiom, digits: "", wildcards: "")
        }
    }

    /// 要看上下文的那几条
    func testContextualIdioms() {
        assertFingerprint("十分重要", digits: "")                  // 十分 = 非常
        assertFingerprint("十分钟", digits: "01")                  // 但十分钟是 10 分钟
        assertFingerprint("十分之一", digits: "01", wildcards: "1") // 十分之一：十还是 10
        assertFingerprint("千万别迟到", digits: "")                 // 千万 = 务必
        assertFingerprint("三千万", digits: "00000003")            // 前面挨着数字就是数
        assertFingerprint("一点半", digits: "", wildcards: "1")     // 一点半 = 1 点半
        assertFingerprint("一点钟", digits: "", wildcards: "1")
        assertFingerprint("星期三", digits: "")                     // 星期 / 周 / 礼拜 + 数字是日期名
        assertFingerprint("周五", digits: "")
        assertFingerprint("礼拜一", digits: "")
        assertFingerprint("上万人", digits: "")                     // 光秃秃一个单位字是约数
    }

    // MARK: - 放行：4.1.6 真正要解决的那一类

    /// 2026-09-21 在 qwen3.8-flash 上实测的七句（提示词第 7 条的验收样本）。
    /// 每一句在 4.1.5 都会被判成 digits changed、整段回退
    func testLiveQwenOutputsPass() {
        let cases: [(String, String)] = [
            ("一共是一百零一人民币然后运费另外算十二块五",
             "一共是101人民币，运费另外算12块5。"),
            ("我是二零一一年毕业的然后二零一九年三月十五号来的",
             "我是2011年毕业的，2019年3月15日来的。"),
            ("下午三点半开会大概两三个人参加十分重要你们千万别迟到",
             "下午3点半开会，大概两三个人参加，十分重要，你们千万别迟到。"),
            ("增长了百分之二十左右大概有一万二千个用户其中三分之一是付费的",
             "增长了20%左右，大概有1.2万个用户，其中三分之一是付费的。"),
            ("电话是幺三八零零幺三八零零零房间号是二零一八",
             "电话是13800138000，房间号是2018。"),
            ("第一次来万一迟到了你先等我一下我们一起走",
             "第一次来，万一迟到了你先等我一下，我们一起走。"),
            ("版本四点一点六修了三个问题跑了七百三十二个测试",
             "版本4.1.6修了3个问题，跑了732个测试。"),
        ]
        for (raw, polished) in cases {
            XCTAssertTrue(TextPostProcessor.numbersPreserved(raw: raw, polished: polished),
                          "numbers should survive: 「\(raw)」→「\(polished)」")
            XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: raw, polished: polished),
                         "drift check should pass: 「\(raw)」→「\(polished)」")
        }
    }

    /// 零散的放行样本
    func testMoreConversionsPass() {
        let cases: [(String, String)] = [
            ("等十分钟", "等10分钟"),
            ("涨了三千万", "涨了3000万"),
            ("来了三个人", "来了3个人"),
            ("这件事十分重要", "这件事非常重要"),          // 成语被润色换掉也不算动数字
            ("万一他不来呢", "如果他不来呢"),
            ("预算是一千块", "预算是1000块"),
            ("走了三点五公里", "走了3.5公里"),
            ("大概有一万二", "大概有1.2万"),
            ("会议在星期三", "会议在星期三。"),
            ("百分之二十的人", "20%的人"),
        ]
        for (raw, polished) in cases {
            XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: raw, polished: polished),
                         "drift check should pass: 「\(raw)」→「\(polished)」")
        }
    }

    // MARK: - 拦住：数值真的变了

    func testChangedNumbersAreRejected() {
        let cases: [(String, String)] = [
            ("一共一百零一块", "一共102块"),                      // 改了一位
            ("我是二零一一年毕业的", "我是2012年毕业的"),
            ("运费十二块五", "运费12块8"),                        // 通配兜不住 8
            ("增长了百分之二十", "增长了30%"),
            ("来了三个人", "来了5个人"),
            ("大概有一万二千个用户", "大概有1.3万个用户"),
            ("一共是一百零一块运费另外十二块", "一共是101块"),      // 整个数字被吞掉
            ("今天开会讨论了方案", "今天开会讨论了50个方案"),        // 凭空多出一个数
            ("电话是幺三八零零幺三八零零零", "电话是1380013800"),    // 少一位
        ]
        for (raw, polished) in cases {
            XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: raw, polished: polished),
                            "drift check should reject: 「\(raw)」→「\(polished)」")
        }
    }

    // MARK: - 第二层：零的位置 / 数位顺序

    /// 汉字转阿拉伯数字最典型的错：**零的位置错了 / 数位调了个儿**。
    /// 这几对的数字字符多重集**一模一样**，第一层一个都拦不住——第二层
    /// 「原文里每个多位数都得原封不动出现在润色里」才是它们的克星
    func testZeroPlacementAndTranspositionAreRejected() {
        // 先钉住"第一层确实看不出来"，免得以后有人以为这几条是多余的
        XCTAssertEqual(fingerprint("一百零一").digits, fingerprint("110").digits)
        XCTAssertEqual(fingerprint("一万零二百").digits, fingerprint("12000").digits)
        XCTAssertEqual(fingerprint("一千零五十").digits, fingerprint("1500").digits)

        let cases: [(String, String)] = [
            ("一共一百零一块", "一共110块"),
            ("一共一万零二百块", "一共12000块"),
            ("一共一万二千块", "一共10200块"),
            ("预算一千零五十", "预算1500"),
            ("我是二零一九年来的", "我是2091年来的"),
            ("一共十二个", "一共21个"),
            ("电话是幺三八零零幺三八零零零", "电话是13008138000"),   // 两位互换
        ]
        for (raw, polished) in cases {
            XCTAssertFalse(TextPostProcessor.numbersPreserved(raw: raw, polished: polished),
                           "numbers should NOT survive: 「\(raw)」→「\(polished)」")
            XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: raw, polished: polished),
                            "drift check should reject: 「\(raw)」→「\(polished)」")
        }
    }

    /// 同一个数换了写法、加了单位、接了小数、改了标点——第二层一律放行（用"包含"不用"相等"）
    func testTheSameNumberWrittenDifferentlyStillPasses() {
        let cases: [(String, String)] = [
            ("运费十二块五", "运费12.5元"),
            ("大概有一万二千个用户", "大概有1.2万个用户"),
            ("大概有一万二千个用户", "大概有12000个用户"),
            ("大概有一万二千个用户", "大概有12,000个用户"),         // 千分位
            ("电话是幺三八零零幺三八零零零", "电话是138-0013-8000"),  // 连字符
            ("电话是幺三八零零幺三八零零零", "电话是138 0013 8000"),  // 空格
            ("涨了三千五百万", "涨了3500万"),
            ("12,000 users", "12000 users"),                     // 原文本来就是阿拉伯数字
            ("版本四点一点六", "版本4.1.6"),                       // 单个数字不产生 token
            ("我是二零一一年毕业的", "我是2011年毕业的。"),
        ]
        for (raw, polished) in cases {
            XCTAssertTrue(TextPostProcessor.numbersPreserved(raw: raw, polished: polished),
                          "numbers should survive: 「\(raw)」→「\(polished)」")
            XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: raw, polished: polished),
                         "drift check should pass: 「\(raw)」→「\(polished)」")
        }
    }

    /// token 只收 ≥ 2 位：单个数字归第一层的多重集 + wildcard 管
    func testNumberTokensOnlyCoverMultiDigitNumbers() {
        XCTAssertEqual(TextPostProcessor.numberTokens(in: "101 和 12000"), ["101", "12000"])
        XCTAssertEqual(TextPostProcessor.numberTokens(in: "4.1.6"), [])
        XCTAssertEqual(TextPostProcessor.numberTokens(in: "3 个人 5 点到"), [])
        // 去重：同一个数出现两次只收一条（个数由第一层的多重集管）
        XCTAssertEqual(TextPostProcessor.numberTokens(in: "2011 和 2011"), ["2011"])
    }

    /// **仍然抓不住的那一种（诚实记在这里）**：两个各自只有一位的数互相换了位置。
    /// 它们在第一层是 wildcard / 单个数字、在第二层不产生 token，两层都看不见。
    /// 要连这个一起抓，得把"这一位挨着哪个词"也记进指纹，那是另一件事。
    func testStillNotCaughtTwoSingleDigitNumbersSwapping() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: "三个人五点到", polished: "5个人3点到"))
    }

    /// **4.1.6 的既定代价，记在这里免得下次被当成 bug**：说话人口头改了一个**数字**
    /// （「十点，不对，是十一点」），润色按提示词第 8 条把说错的那个删掉——从数字指纹看
    /// 就是"少了一个数"，而数字这条是零容差的（少一位可能就是金额 / 房号错），于是回退原文。
    /// 失败方向是安全的：用户拿到自己说的原话（含那句「不对」），只是没被润色。
    /// 4.1.5 之所以不拦，是因为那时两边的汉字数字都数不出阿拉伯数字来——不是它更聪明。
    func testSelfCorrectedNumberFallsBackToTheRawText() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(
            raw: "明天上午十点，不对，是十一点", polished: "明天上午11点。"))
        // 改的不是数字就照常放行
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "明天上午开会，不对，是下午开会", polished: "明天下午开会。"))
    }

    // MARK: - 老规矩一条都不许破

    /// 阿语：数字是词（خمسة），ITN 只能由润色做，所以纯新增数字照旧放行；
    /// 但凡有一位被删被改，照样拦
    func testArabicToleranceUnchanged() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "لدينا خمسة اجتماعات اليوم", polished: "لدينا 5 اجتماعات اليوم."))
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: "الموعد ٢٠٢٦", polished: "الموعد 2026."))
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "الموعد ٢٠٢٦", polished: "الموعد 2027."))
    }

    /// 失败原因只报个数，绝不带数字本身（它会进日志 → 进「复制诊断信息」）
    func testReasonStillCarriesNoDigits() {
        let reason = TextPostProcessor.polishDriftCheck(raw: "验证码是四八二一", polished: "验证码是4822")
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("digits changed"))
        XCTAssertFalse(reason!.contains("4821"))
        XCTAssertFalse(reason!.contains("4822"))
    }
}
