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

    // MARK: - 编号列表的序号（4.2.1）

    /// 提示词第 8 条**要求**润色把多个要点整理成编号列表，于是成品里凭空多出「1. 2. 3.」——
    /// 原文里一个数字都没有。4.1.6 的用户日志里 `rawCount=0 polishedCount=5 distinct=0/4`
    /// 就是这么来的（四个要点 + 一个别的数），长口述最需要润色，却每次都被拦。
    func testNumberedListMarkersArePass() {
        let cases: [(String, String)] = [
            // 提示词自带的那个示范
            ("嗯那个方案我想了一下其实现在最大的问题是时间太紧然后人也不够嗯预算其实有点超了所以要么砍掉一部分功能要么往后推两周大概这个意思",
             "关于这个方案，目前主要有三个问题：\n1. 时间太紧；\n2. 人手不够；\n3. 预算略有超支。\n建议二选一：砍掉部分功能，或往后推两周。"),
            // 首先 / 然后 / 最后 → 编号
            ("首先要把合同发出去然后给客户回个电话最后把报销单交了",
             "1. 把合同发出去\n2. 给客户回电话\n3. 提交报销单"),
            // 行内列表（分号分隔）
            ("主要有三点第一个是时间第二个是人手第三个是预算",
             "主要有三点：1. 时间；2. 人手；3. 预算。"),
            // 括号形式
            ("两件事一个是合同一个是发票", "两件事：(1) 合同 (2) 发票"),
        ]
        for (raw, polished) in cases {
            XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: raw, polished: polished),
                         "编号列表不该被判成凭空多出数字：\(polished)")
        }
    }

    /// 列表项**里面**的真数字照样一位不许变
    func testNumbersInsideListItemsAreStillChecked() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "第一预算是一百零一万第二时间要两周",
            polished: "1. 预算101万\n2. 时间两周"))
        // 数值改了照样拦
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(
            raw: "第一预算是一百零一万第二时间要两周",
            polished: "1. 预算102万\n2. 时间两周"))
    }

    /// 引出句里的**条数**同样是润色数出来的，不是说话人说的。
    /// 4.2.1 的联网验收里真碰到了：说话人说「有几个问题」，模型写「目前主要有3个问题：」
    /// 外加 1. 2. 3. 三条——序号摘掉之后，那个 3 成了没人认领的多余数字
    /// （日志 `digits changed rawCount=0 polishedCount=3 … listMarkers=3`）。
    func testListCountInTheLeadInSentenceIsCovered() {
        let raw = "这个项目现在有几个问题嗯首先是时间太紧我们原来定的是这个月底但是现在看起来肯定来不及"
            + "然后就是人手也不够本来说好的两个人现在只有一个人还有就是预算这块其实已经超了一些了"
            + "所以我的想法是要么我们把范围砍一砍要么就往后推一推大概就是这个意思你看一下"
        let polished = "关于这个项目，目前主要有3个问题：\n1. 时间太紧，原定本月底完成；"
            + "\n2. 人手不足：原计划2人，现仅1人；\n3. 预算超支。\n建议缩减范围或推迟交付。"
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: raw, polished: polished))
    }

    /// **联网实测抓到的那一句**（三遍里挂一遍）：润色一边把口语的「两个人 / 一个人」转成
    /// 「2人 / 1人」，一边自己新造了「三个问题」「二选一」两个汉字数字。
    /// 4.2.1 之前 extra 池要减去润色侧的 wildcard，新造的那个「二」正好抵掉了本该解释
    /// 「2人」的那个 wildcard 2 —— 一段忠实的润色就这么被丢回原文。
    func testPolishMintingItsOwnChineseNumeralsDoesNotCancelTheRawWildcards() {
        let raw = "这个项目现在有几个问题嗯首先是时间太紧我们原来定的是这个月底但是现在看起来肯定来不及"
            + "然后就是人手也不够本来说好的两个人现在只有一个人还有就是预算这块其实已经超了一些了"
            + "所以我的想法是要么我们把范围砍一砍要么就往后推一推大概就是这个意思你看一下"
        let polished = "关于这个项目，目前主要有三个问题：\n1. 时间太紧，原定月底完成，现在看肯定来不及；"
            + "\n2. 人手不够，原计划2人，现在只有1人；\n3. 预算已超支。"
            + "\n建议二选一：要么缩减项目范围，要么延后交付时间。请看一下。"
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: raw, polished: polished))
    }

    /// **已知代价，诚实记在这里**（4.2.1 拿掉 extra 池那道减法换来的）：
    /// 原文里有一个孤立的汉字数字时，它可以解释一个同值的阿拉伯数字，
    /// 哪怕那个汉字还原样留在成品里。换来的是上面那一类不再被误杀。
    /// 守卫真正的底线没松：见下面两条——原文没有数字就一个都兜不住，值不对照样拦。
    func testKnownCostABareNumeralCanExplainOneSameValuedDigit() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: "三个人来", polished: "三个人来，花了3小时"))
    }

    /// 原文一个数字都没有 → 池子是空的，凭空造一个数照样拦
    func testInventedDigitWithNoNumeralInTheRawIsStillRejected() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "今天开会讨论了方案",
                                                           polished: "今天开会讨论了3个方案"))
    }

    /// 值不对照样拦：原文说两个人，成品写 5 人
    func testAWildcardOnlyExplainsItsOwnValue() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "本来说好的两个人",
                                                           polished: "本来说好5人"))
    }

    /// 条数**说错了**就不放过：3 条列表配「4个问题」，那个 4 没人认领
    func testAWrongListCountIsStillRejected() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(
            raw: "这几个事都得办合同要发邮件要回会议室要订",
            polished: "主要有4个问题：\n1. 发合同\n2. 回邮件\n3. 订会议室"))
    }

    /// 条数对了也只放过条数那一位：条目里凭空冒出来的数照样拦
    func testTheListCountDoesNotExcuseInventedNumbersInItems() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(
            raw: "这几个事都得办预算要定延期要谈人手要补",
            polished: "主要有3个问题：\n1. 预算50万\n2. 延期\n3. 补人手"))
    }

    /// 两位数的条数（共12项）同样算数
    func testTwoDigitListCountIsCovered() {
        let items = (1...12).map { "\($0). 要办的一件事" }.joined(separator: "\n")
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "今天要办的事挺多的一件一件说吧",
            polished: "共12项：\n" + items))
    }

    /// 列表条数那桶软数字出身在**润色侧**，只解释润色多出来的位，
    /// 绝不参与「原文有、润色没有」那一侧
    func testListCountSoftDigitsOnlyExplainPolishedExtras() {
        let fingerprint = TextPostProcessor.numericFingerprint("有3件事：\n1. 甲\n2. 乙\n3. 丙")
        XCTAssertEqual(TextPostProcessor.digitSummary(fingerprint.listCountDigits), "3")
        // 没摘到连号列表就没有这桶
        XCTAssertEqual(TextPostProcessor.numericFingerprint("有3件事").listCountDigits, [:])
        // 原文说了数字、润色把它丢了 —— 列表条数不能替它开脱
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(
            raw: "预算是一百零一万还有三件事要办",
            polished: "有3件事：\n1. 甲\n2. 乙\n3. 丙"))
    }

    /// **假列表偷渡不进来**：原文没有的数字，套一层「1. 2.」照样拦
    func testAFakeListCannotSmuggleANumber() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(
            raw: "预算的事还要再看看延期的事也要定下来",
            polished: "1. 预算50万\n2. 延期"))
    }

    /// 只有连成 1,2,…,n（n ≥ 2）才算列表；别的一律当数据，一个字都不动
    func testOnlyAConsecutiveSequenceCountsAsAList() {
        XCTAssertEqual(TextPostProcessor.strippedOfListMarkers("版本4.1.6").markers, 0)
        XCTAssertEqual(TextPostProcessor.strippedOfListMarkers("1.5元，2.5元").markers, 0)
        XCTAssertEqual(TextPostProcessor.strippedOfListMarkers("1. 只有一条").markers, 0)
        XCTAssertEqual(TextPostProcessor.strippedOfListMarkers("3. 这个 5. 那个").markers, 0)
        XCTAssertEqual(TextPostProcessor.strippedOfListMarkers("1. 这个\n2. 那个").markers, 2)
        // 摘掉的只是序号本身，正文里的数字原样留着
        XCTAssertEqual(TextPostProcessor.numericFingerprint("1. 预算101万\n2. 两周").digits,
                       TextPostProcessor.numericFingerprint("预算101万 两周").digits)
    }

    // MARK: - 时间（4.2.1）

    /// 「一点」以前被整条当成口头禅摘掉，于是润色写出来的「1点」成了没人认领的多余数字
    func testClockHoursSurvive() {
        let cases: [(String, String)] = [
            ("明天下午一点开会", "明天下午1点开会"),
            ("一点到三点都有空", "1点到3点都有空"),
            ("三点十分结束", "3点10分结束"),
            ("三点十分结束", "3:10结束"),
            ("下午三点半再碰一次", "下午3点半再碰一次"),
            ("下午三点半再碰一次", "下午3:30再碰一次"),
            ("下午三点半再碰一次", "下午15:30再碰一次"),
            ("晚上八点一刻出发", "晚上8:15出发"),
            ("有一点累", "有点累"),                      // 「一点」= 一些 的那一支照样放行
        ]
        for (raw, polished) in cases {
            XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: raw, polished: polished),
                         "时间说法不该被判跑飞：「\(raw)」→「\(polished)」")
        }
    }

    /// 钟点改错了照样拦——软数字只解释"说法自带的那几位"，不解释别的
    func testWrongClockTimeIsStillRejected() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "下午三点开会", polished: "下午16:00开会"))
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "三点十分结束", polished: "3点20分结束"))
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "一点到三点", polished: "1点到4点"))
    }

    /// 「十分」的两副面孔：前面挨着点 / 数字时是 10，别处是"非常"
    func testTenMinutesVersusVeryMuch() {
        assertFingerprint("三点十分", digits: "01", wildcards: "3")
        assertFingerprint("四十分钟", digits: "04")
        assertFingerprint("十分重要", digits: "")
        assertFingerprint("这件事十分好", digits: "")
    }

    /// 软数字只站在"解释多出来的位"这一侧，绝不要求对面出现
    func testSoftDigitsOnlyExplainExtras() {
        XCTAssertEqual(TextPostProcessor.digitSummary(TextPostProcessor.softDigits(in: "三点半")), "03")
        XCTAssertEqual(TextPostProcessor.digitSummary(TextPostProcessor.softDigits(in: "八点一刻")), "15")
        XCTAssertEqual(TextPostProcessor.digitSummary(TextPostProcessor.softDigits(in: "九点三刻")), "45")
        XCTAssertEqual(TextPostProcessor.digitSummary(TextPostProcessor.softDigits(in: "下午三点")), "15")
        XCTAssertEqual(TextPostProcessor.digitSummary(TextPostProcessor.softDigits(in: "上午三点")), "")
        // 「三点半」→「3点半」：软数字没被用上也不影响
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: "三点半开会", polished: "3点半开会"))
    }

    // MARK: - 英文数字词（4.2.1）

    /// gpt-5.6-luna 不管提示词怎么写都会自己把 "twenty five dollars" 写成 "$25"——
    /// 这道校验以前只认汉字数字，于是每一句带英文数字词的听写都回退原文
    func testEnglishNumberWordsPass() {
        let cases: [(String, String)] = [
            ("it costs twenty five dollars", "It costs $25."),
            ("let's meet on March third", "Let's meet on March 3."),
            ("let's meet on March third", "Let's meet on March 3rd."),
            ("call me at nine thirty", "Call me at 9:30."),
            ("we shipped it in two thousand twenty six", "We shipped it in 2026."),
            ("we shipped it in twenty twenty six", "We shipped it in 2026."),
            ("there were a hundred and one issues", "There were 101 issues."),
            ("three people came", "3 people came."),
            ("one of the things we discussed", "One of the things we discussed."),
            ("one of the things we discussed", "One thing we discussed."),
        ]
        for (raw, polished) in cases {
            XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: raw, polished: polished),
                         "英文数字不该被判跑飞：「\(raw)」→「\(polished)」")
        }
    }

    /// 英文数值改了照样拦
    func testEnglishNumbersChangedAreRejected() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "it costs twenty five dollars",
                                                           polished: "It costs $35."))
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "fifteen people came",
                                                           polished: "50 people came."))
    }

    /// 英文数字的口径对照表
    func testEnglishNumberFingerprints() {
        assertFingerprint("twenty five", digits: "25")
        assertFingerprint("twenty-five", digits: "25")
        assertFingerprint("Twenty Five", digits: "25")          // 大小写不敏感
        assertFingerprint("fifteen", digits: "15")
        assertFingerprint("a hundred and one", digits: "011")
        assertFingerprint("two thousand twenty six", digits: "0226")
        assertFingerprint("twenty twenty six", digits: "0226")   // 20 + 26，位数和 2026 一样
        assertFingerprint("nine thirty", digits: "03", wildcards: "9")
        assertFingerprint("three", digits: "", wildcards: "3")
        assertFingerprint("March third", digits: "", wildcards: "3")
        // **绝不能在别的词里面认出数字**
        assertFingerprint("none someone often tension anyone", digits: "", wildcards: "")
        assertFingerprint("hundreds of people", digits: "", wildcards: "")
    }

    // MARK: - 日志旗子（4.2.1）

    /// 失败原因后面那几面旗子：只有个数与真假，一个字都不来自用户
    func testFailureFlagsAreDiagnosticButCarryNoContent() {
        let reason = TextPostProcessor.polishDriftCheck(raw: "预算的事再看看", polished: "1. 预算50万\n2. 延期")
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("extra="))
        XCTAssertTrue(reason!.contains("missing="))
        XCTAssertTrue(reason!.contains("listMarkers="))
        XCTAssertTrue(reason!.contains("rawTimeWords="))
        XCTAssertTrue(reason!.contains("rawEnglishNumbers="))
        XCTAssertFalse(reason!.contains("50"))          // 数字本身永远不许出现
        XCTAssertFalse(reason!.contains("预算"))
        // 时间 / 英文那两面旗子确实会亮
        let timeReason = TextPostProcessor.polishDriftCheck(raw: "下午三点开会", polished: "下午16:00开会")
        XCTAssertTrue(timeReason?.contains("rawTimeWords=true") ?? false)
        let englishReason = TextPostProcessor.polishDriftCheck(raw: "it costs twenty five dollars",
                                                              polished: "It costs $35.")
        XCTAssertTrue(englishReason?.contains("rawEnglishNumbers=true") ?? false)
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
