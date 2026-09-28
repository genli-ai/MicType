import XCTest
@testable import MicType

/// 5.0.6 的三道新保真闸门（文字翻转 / 否定范围 / 人名同音）+ 过长判据 + 列表豁免。
/// 用例大半移植自 iOS `PolishGuardTests`（2026-09-28 terra 真机 C1 / C2 与必须放行的真机输出），
/// 另加阿拉伯语一组：阿语是必须支持的输入语言，每道闸门都要拿阿语过一遍。
final class PolishFidelityTests: XCTestCase {

    private func verdict(_ raw: String, _ polished: String, glossary: [String] = []) -> String? {
        TextPostProcessor.polishDriftCheck(raw: raw, polished: polished, glossary: glossary)
    }

    private func assertRejected(_ raw: String, _ polished: String, prefix: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let reason = verdict(raw, polished)
        XCTAssertNotNil(reason, "expected \(prefix)", file: file, line: line)
        XCTAssertTrue(reason?.hasPrefix(prefix) == true, "got \(reason ?? "nil")", file: file, line: line)
    }

    // MARK: - 基线

    func testFaithfulPolishesPass() {
        XCTAssertNil(verdict("嗯那个我明天下午三点到然后我们一起去吃饭吧", "我明天下午3点到，然后我们一起去吃饭吧。"))
        XCTAssertNil(verdict("i think we should ship it tomorrow you know", "I think we should ship it tomorrow."))
        XCTAssertNil(verdict("没事的人家都没有封掉这个网页", "没事的，人家都没有封掉这个网页。"))
        XCTAssertNil(verdict("好的明天见", "好的，明天见！"))
    }

    // MARK: - 文字系统翻转

    /// 2026-09-22 live 评测：gpt-5.6 把含「用英语来回答」的中文口述真的译成了英文——铁律 1 违例
    func testTranslationToEnglishIsRejected() {
        assertRejected("用英语来回答，我的老板是一个澳大利亚人", "Please answer in English. My boss is Australian.",
                       prefix: "script flipped")
        assertRejected("请用英语来回答这个问题我想知道明天的会议几点开始",
                       "What time does tomorrow's meeting start? Please answer in English.",
                       prefix: "script flipped")
        assertRejected("OK let's go", "好，我们走", prefix: "script flipped")
    }

    /// 原因串只有百分比，绝不带用户的话
    func testScriptFlipReasonCarriesPercentagesOnly() {
        let reason = PolishFidelity.scriptFlipReason(raw: "用英语来回答，我的老板是一个澳大利亚人",
                                                     polished: "Please answer in English. My boss is Australian.")
        XCTAssertEqual(reason, "script flipped rawHan=100% polHan=0% rawAr=0% polAr=0%")
    }

    /// 混排（10–60%）永不判：中英混说正是铁律 1 要保护的
    func testMixedLanguageIsNeverJudged() {
        XCTAssertNil(verdict("这个 feature 的 demo 我明天给你看", "这个 feature 的 demo 我明天给你看。"))
        XCTAssertNil(verdict("我明天用 Python 写一下 demo", "我明天用 Python 写个 demo。"))
        XCTAssertNil(verdict("我在用那个语音输入软件", "我在用那个 MicType 语音输入软件。"))
        XCTAssertNil(PolishFidelity.scriptFlipReason(raw: "我们 review 一下 the pull request",
                                                     polished: "我们 review 一下这个 pull request。"))
    }

    /// 字母不足 4 个不判；数字、标点、emoji 不计
    func testTooFewLettersAreNotJudged() {
        XCTAssertNil(PolishFidelity.scriptShares("OK 好"))
        XCTAssertEqual(PolishFidelity.scriptCounts("2026 年 ٢٠٢٦ ۔ 😀").total, 1)
    }

    // MARK: - 阿拉伯语（每道闸门都要拿阿语过一遍）

    /// 模型对阿语基本不吐标点，补标点正是润色在阿语上最主要的工作
    func testArabicPunctuationOnlyPasses() {
        XCTAssertNil(verdict("مرحبا كيف حالك اليوم", "مرحبا، كيف حالك اليوم؟"))
    }

    /// 阿语数字是词（خمسة），ITN 只能由润色做：词 → 数字放行（既有容差），文字翻转也不误判
    func testArabicNumberWordsToDigitsPass() {
        XCTAssertNil(verdict("عندي خمسة اجتماعات غدا في الصباح", "عندي 5 اجتماعات غدًا في الصباح."))
    }

    /// 正常改写（长度相近、全是阿语）：scope / 人名两道闸门都不该碰它
    func testArabicOrdinaryRewritePasses() {
        let raw = "انا اريد ان اذهب الى السوق غدا مع اخي"
        let polished = "أريد أن أذهب إلى السوق غدًا مع أخي."
        XCTAssertNil(verdict(raw, polished))
        XCTAssertEqual(PolishFidelity.negationScopeVerdict(raw: raw, polished: polished).unmatched, 0)
        XCTAssertEqual(PolishFidelity.negationScopeVerdict(raw: raw, polished: polished).overAffirmed, 0)
        XCTAssertEqual(PolishFidelity.homophoneNameChanges(raw: raw, polished: polished, glossary: []), 0)
        // 阿语里夹一个英文词不算混排翻转
        XCTAssertNil(verdict("ارسل لي ملف PDF من فضلك", "أرسل لي ملف PDF من فضلك."))
    }

    /// 阿语整段被译成英文 → 拦；反方向（英文 → 阿语、中文 → 阿语）同样拦
    func testArabicTranslationIsRejected() {
        let reason = verdict("اريد ان اذهب الى السوق غدا مع اخي",
                             "I want to go to the market tomorrow with my brother.")
        XCTAssertEqual(reason, "script flipped rawHan=0% polHan=0% rawAr=100% polAr=0%")
        assertRejected("I want to go to the market tomorrow", "أريد أن أذهب إلى السوق غدًا", prefix: "script flipped")
        assertRejected("我明天想和哥哥去市场", "أريد أن أذهب إلى السوق غدًا مع أخي", prefix: "script flipped")
    }

    // MARK: - 长度与列表

    /// iOS 2026-07-10 真机：47→95，模型回答了口述里的问题
    func testAnsweredInsteadOfPolishedIsRejected() {
        let raw = "你觉得我们这个功能应该先做哪一个比较好呢是先做引导还是先做设置页"
        let answered = raw + "。我认为应该先做引导，因为引导决定了用户的第一印象，而设置页只有在用户已经留下来之后才会被打开，所以优先级上引导更高一些。"
        assertRejected(raw, answered, prefix: "too long")
        XCTAssertEqual(verdict("帮我回复一下客户", "好的，我这就帮您回复客户：您好，关于您上次提到的问题，我们已经安排了专人跟进，预计本周内给您答复，请您耐心等待。"),
                       "too long raw=8 polished=56")
    }

    /// 长口述被整理成编号列表（变长）→ 放行；•列表同理
    func testListsAreExemptFromTooLong() {
        let raw = "首先要把合同发出去然后给客户回个电话还有订一下会议室"
        let numbered = "今天的待办如下：\n\n1. 把合同发给法务部门审核\n2. 给客户回个电话确认细节\n3. 预订下周二上午的会议室"
        XCTAssertGreaterThan(numbered.count, Int(Double(raw.count) * 1.5) + 10, "这条用例得真的触发过长判据")
        XCTAssertNil(verdict(raw, numbered))
        let bullets = "今天的待办如下：\n\n• 把合同发给法务部门审核\n• 给客户回个电话确认细节\n• 预订下周二上午的会议室"
        XCTAssertNil(verdict(raw, bullets))
        // 同样的长度、不是列表 → 拦
        let prose = "今天的待办如下：先把合同发给法务部门审核，再给客户回个电话确认细节，最后预订下周二上午的会议室，都要今天办完。"
        XCTAssertGreaterThan(prose.count, Int(Double(raw.count) * 1.5) + 10)
        assertRejected(raw, prose, prefix: "too long")
    }

    /// 孤零零一个「1.」是数据，不是列表（与数字指纹同一个答案）
    func testLooksLikeList() {
        XCTAssertTrue(PolishFidelity.looksLikeList("• 一\n• 二"))
        XCTAssertTrue(PolishFidelity.looksLikeList("待办：\n\n• 一"))
        XCTAssertTrue(PolishFidelity.looksLikeList("主要有两点：\n1. 时间紧\n2. 人手不够"))
        XCTAssertTrue(PolishFidelity.looksLikeList("1、时间紧\n2、人手不够"))
        XCTAssertTrue(PolishFidelity.looksLikeList("1) 时间紧\n2) 人手不够"))
        XCTAssertFalse(PolishFidelity.looksLikeList("1. 我们明天去"))
        XCTAssertFalse(PolishFidelity.looksLikeList("版本 4.1.6 修了 3 个问题"))
    }

    /// 2026-07-11 iOS 真机：107→57。过短同样有列表豁免
    func testSummarizedIsRejectedButListsExempt() {
        // 与 iOS 用例不同的是这里换掉了「不太一样」：Mac 的否定计数没有列表豁免（任务书：保留 Mac
        // 现有否定阈值），4 个「不」收成 1 个会先被计数规则拦下，测不到长度这条
        let raw = String(repeating: "我们今天讨论了很多关于产品方向的事情然后大家意见有些分歧", count: 4)
        assertRejected(raw, "大家对产品方向有分歧。", prefix: "too short")
        XCTAssertNil(verdict(raw, "今天的讨论：\n• 产品方向\n• 意见有些分歧"))
    }

    // MARK: - 否定范围（C1）

    /// C1：一个否定进、一个否定出，两条计数规则都看不见——原文的「不需要」撞上半截分句，
    /// 「换…滤芯」在「其实就是要」之后（被肯定），润色却否定了它
    func testC1NegationMovedOntoAffirmedObjectIsRejected() {
        XCTAssertEqual(verdict("我感觉不需要把其实就是要换一下那个滤芯的问题", "我感觉不需要更换滤芯"),
                       "negation scope changed unmatched=0 overAffirmed=1")
        XCTAssertEqual(verdict("我觉得不用了吧其实就是要重启一下路由器", "我觉得不用重启路由器。"),
                       "negation scope changed unmatched=0 overAffirmed=1")
    }

    func testC1FaithfulPolishesPass() {
        XCTAssertNil(verdict("我感觉不需要把其实就是要换一下那个滤芯的问题", "我感觉不需要，其实就是要换一下滤芯。"))
        XCTAssertNil(verdict("不需要换滤芯就是清洗一下", "不需要换滤芯，清洗一下就行。"))
        XCTAssertNil(verdict("不是其实我也不想去北京出差", "其实我也不想去北京出差。"))
    }

    /// 润色里**留下来的**独立成句否定（「没有，」「不，」）就是回答里的否定，不是被删掉的口头纠正。
    /// 5.0.6 之前 Mac 的计数只有严口径（把它们摘掉），原文没标点照常数 1 → 判 negation lost；
    /// 现在润色一侧再数一遍宽口径（留着它们），「吞光」要两种口径都为 0。
    func testKeptStandaloneNegationAnswerPasses() {
        for (raw, polished) in [("没有但是我可以帮你问问", "没有，但我可以帮你问问。"),
                                ("没有啦我就随便问问", "没有，我就随便问问。"),
                                ("不我自己来就行啊", "不，我自己来就行。")] {
            XCTAssertNil(verdict(raw, polished), raw)
        }
        XCTAssertEqual(TextPostProcessor.negationCount("没有，但我可以帮你问问。"), 0)
        XCTAssertEqual(TextPostProcessor.negationCount("没有，但我可以帮你问问。", keepStandalone: true), 1)
    }

    /// 「no no no」这条仍被计数规则拦下，**刻意不再放宽**：原文 4 个（no×3 + n't），润色宽口径 2 个
    /// （No + n't），差 2 > max(1, 4/3)。范围规则本身放行它。
    func testEnglishNoNoNoIsStillBlockedByCount() {
        let raw = "no no no i didn't mean that", polished = "No, I didn't mean that."
        let scope = PolishFidelity.negationScopeVerdict(raw: raw, polished: polished)
        XCTAssertEqual(scope.unmatched, 0)
        XCTAssertEqual(scope.overAffirmed, 0)
        XCTAssertEqual(verdict(raw, polished), "negation drift raw=4 polished=2")
    }

    /// 宽口径不许把真丢掉的否定放过去
    func testRealLostNegationIsStillCaughtWithLooseCount() {
        XCTAssertEqual(verdict("我不去", "我去"), "negation lost raw=1 polished=0")
        XCTAssertEqual(verdict("不，我不去", "我去。"), "negation lost raw=1 polished=0")
        // 「没问题」还在、「不去」变成「去」：计数 2→1 在容差内，范围规则抓到
        XCTAssertEqual(verdict("没有问题我不去", "没问题，我去。"),
                       "negation scope changed unmatched=1 overAffirmed=0")
    }

    /// 说话人在「我是说 / 不对 / 应该是」之前收回的否定不保护
    func testSelfCorrectionDropsFillerNegation() {
        XCTAssertNil(verdict("不是，我是说明天不去了", "我是说明天不去了"))
        XCTAssertNil(verdict("你说的不对应该是周三不是周四", "你说得不对，应该是周三，不是周四。"))
    }

    /// 否定跟着宾语走：句子重排、中心词缩短（没有→没）、不要→别，都放行
    func testKeptNegationWithRestructurePasses() {
        XCTAssertNil(verdict("我不太想去，但是可以陪你", "我不太想去，但可以陪你。"))
        XCTAssertNil(verdict("我觉得这个事情没有那么简单", "我觉得这件事没那么简单。"))
        XCTAssertNil(verdict("你别忘了明天带那个充电器", "明天别忘了带充电器。"))
        XCTAssertNil(verdict("我觉得不太好吧这个方案", "我觉得这个方案不太好。"))
        XCTAssertNil(verdict("我没办法明天去那个会你帮我请个假", "我明天没办法去开会，你帮我请个假。"))
        XCTAssertNil(verdict("不要忘了下午三点开会", "别忘了下午3点开会。"))
        XCTAssertNil(verdict("这不就是一个电风扇吗", "这不就是一个电风扇吗？"))
    }

    /// 没标点的原文把句末否定和下一句连着写（「不用了谢谢你」被读成 不用 → 谢谢），
    /// 润色只是把逗号加回去：没有宾语、开头相同的润色否定覆盖它
    func testClauseFinalNegationThenPunctuatedPasses() {
        XCTAssertNil(verdict("不用了谢谢你啊", "不用了，谢谢你。"))
        XCTAssertNil(verdict("不用了谢谢你", "不用，谢谢你。"))
        XCTAssertNil(verdict("不用不用我自己来就行", "不用，我自己来就行。"))
    }

    /// 另一半：否定从一个仍然在场的宾语上掉了。2→1 在计数容差之内，只有范围规则看得见；
    /// 句末的「不用，」不能覆盖另一个中心词（「不需要帮忙」）
    func testNegationFellOffSurvivingObjectIsRejected() {
        XCTAssertEqual(verdict("我不去了你们也不用等我", "我不去了，你们等我。"),
                       "negation scope changed unmatched=1 overAffirmed=0")
        XCTAssertEqual(verdict("不用了你别管我了我不需要帮忙", "不用了，你别管我了，我需要帮忙。"),
                       "negation scope changed unmatched=1 overAffirmed=0")
        XCTAssertEqual(verdict("我不去北京了我去上海", "我去北京，不去上海。"),
                       "negation scope changed unmatched=1 overAffirmed=0")
    }

    /// 列表不查范围：合并要点时否定跟着挪位置是正常的
    func testListsAreExemptFromNegationScope() {
        XCTAssertNil(verdict("我不去北京了我去上海然后周五回来",
                             "行程如下：\n• 去北京\n• 不去上海\n• 周五回来"))
    }

    // MARK: - 人名同音（C2）

    /// C2：第 5 条同音纠错用在了人名上。原因串只有计数，绝不带名字
    func testC2HomophoneNameIsRejected() {
        let reason = verdict("早上好呀，我去跟汉总说一下", "早上好，我去跟韩总说一下")
        XCTAssertEqual(reason, "person name changed to a homophone count=1")
        XCTAssertFalse(reason?.contains("汉") == true || reason?.contains("韩") == true)
    }

    /// 只靠确定性规则（不让 NLTagger 替它兜着）也要拦得住：Mac 最低 macOS 15，
    /// NLTagger 在那上面认不认中文人名没验证过
    func testHeuristicAloneCatchesSwap() {
        func swaps(_ raw: String, _ polished: String) -> Int {
            PolishFidelity.homophoneSwaps(of: PolishFidelity.heuristicNames(in: raw),
                                          raw: raw, polished: polished, glossary: [])
        }
        XCTAssertEqual(PolishFidelity.heuristicNames(in: "早上好呀，我去跟汉总说一下"), ["汉总"])
        XCTAssertEqual(swaps("早上好呀，我去跟汉总说一下", "早上好，我去跟韩总说一下"), 1)
        XCTAssertEqual(swaps("明天我找汉明签字吧", "明天我找韩明签字。"), 1)
        XCTAssertEqual(swaps("因为嘉士奇它本质上就是一个电风扇", "因为加湿器本质上就是一个电风扇"), 0)
    }

    /// 普通名词的同音纠错是第 5 条的本职（嘉士奇没有人名读法）；小王读作人名，但没被同音替换
    func testCommonNounHomophoneFixPasses() {
        XCTAssertNil(verdict("因为嘉士奇它本质上就是一个电风扇", "因为加湿器本质上就是一个电风扇"))
        XCTAssertNil(verdict("上小王和优次会表", "上下文和词汇表"))
    }

    /// 称呼 / 引出词旁边的日常同音纠错：的→得、老师→老是、同是→同事、会总→汇总
    func testEverydayHomophoneFixesNearIntroducersOrTitlesPass() {
        XCTAssertNil(verdict("我和他跑的很快", "我和他跑得很快。"))
        XCTAssertNil(verdict("他老师迟到", "他老是迟到。"))
        XCTAssertNil(verdict("我和同是去吃饭", "我和同事去吃饭。"))
        XCTAssertNil(verdict("帮我会总一下数据", "帮我汇总一下数据。"))
    }

    /// 名字保留放行；繁转简（第 6 条：中文一律简体）不是改名
    func testKeptOrSimplifiedNamePasses() {
        XCTAssertNil(verdict("早上好呀，我去跟汉总说一下", "早上好，我去跟汉总说一下。"))
        XCTAssertTrue(PolishFidelity.heuristicNames(in: "我去跟王總說一下吧").contains("王總"))
        XCTAssertNil(verdict("我去跟王總說一下吧", "我去跟王总说一下。"))
        XCTAssertEqual(PolishFidelity.simplified("王總說"), "王总说")
    }

    /// 词汇表那一行要求模型把听错的名字改成用户的写法：改成词汇表写法不算改名
    func testGlossarySpellingIsExempt() {
        XCTAssertNil(verdict("早上好呀，我去跟汉总说一下", "早上好，我去跟韩总说一下", glossary: ["韩总", "MicType"]))
        XCTAssertEqual(verdict("早上好呀，我去跟汉总说一下", "早上好，我去跟韩总说一下", glossary: ["MicType"]),
                       "person name changed to a homophone count=1")
    }

    /// 整个规则立在「逐字无调拼音」上
    func testPinyinIsToneless() {
        XCTAssertEqual(PolishFidelity.pinyin("汉"), "han")
        XCTAssertEqual(PolishFidelity.pinyin("韩"), "han")
        XCTAssertEqual(PolishFidelity.pinyin("總"), PolishFidelity.pinyin("总"))
        XCTAssertNotEqual(PolishFidelity.pinyin("王"), PolishFidelity.pinyin("汉"))
        XCTAssertNil(PolishFidelity.pinyin("a"))
    }

    /// NLTagger（语言固定简体中文）能分语境：「让高明来一趟」是人名，「这个方案很高明」不是。
    /// iOS 2026-09-28 在 macOS 26 上探测过；macOS 15 未验证——认不出基线人名的系统上跳过，
    /// 那里靠的是确定性规则（上面那条单测）。
    func testTaggerReadsContextWhereAvailable() throws {
        guard PolishFidelity.taggedNames(in: "我去跟王总说一下").contains("王总") else {
            throw XCTSkip("这台系统的 NLTagger 不认中文人名，名字闸门靠确定性规则")
        }
        XCTAssertTrue(PolishFidelity.taggedNames(in: "让高明来一趟").contains("高明"))
        XCTAssertFalse(PolishFidelity.taggedNames(in: "这个方案很高明").contains("高明"))
        XCTAssertEqual(verdict("你让高明来一趟", "你让高鸣来一趟。"), "person name changed to a homophone count=1")
        XCTAssertNil(verdict("这个方案很高明啊", "这个方案很高明。"))
    }

    // MARK: - 真机必须放行（iOS 2026-09-28 terra 输出）

    func testDeviceOutputsPass() {
        XCTAssertNil(verdict("Hello hello 现在是星期五", "Hello，现在是星期五。"))
        XCTAssertNil(verdict("然后友谊个润色出现了明显的意思的偏差", "润色后出现了明显的语义偏差"))
        XCTAssertNil(verdict("那个 QR code 怎么申请啊？", "QR code 怎么申请？"))
    }

    // MARK: - 中英空格照原文补回

    private func restored(_ raw: String, _ polished: String) -> String {
        TextPostProcessor.restoreLatinHanSpaces(raw: raw, polished: polished)
    }

    /// 5.0.6 live 评测 terra 3 轮里 1 次：「QR code 怎么」→「QR code怎么」
    func testRestoresDroppedSpaceAfterLatinWord() {
        XCTAssertEqual(restored("那个 QR code 怎么申请啊？", "QR code怎么申请？"), "QR code 怎么申请？")
        XCTAssertEqual(restored("打开 App Store 下载", "打开App Store下载。"), "打开 App Store 下载。")
        XCTAssertEqual(restored("我明天用 python 写", "我明天用Python写。"), "我明天用 Python 写。")   // 不分大小写
    }

    /// 原文本来就粘着写：润色也照样粘着，不替用户加空格
    func testGluedInRawStaysGlued() {
        XCTAssertEqual(restored("那个QR code怎么申请啊", "QR code怎么申请？"), "QR code怎么申请？")
        XCTAssertEqual(restored("我用App下载", "我用App下载。"), "我用App下载。")
    }

    /// 数字与汉字之间不加空格是第 7 条：「3 个」→「3个」不许被补回去，贴着汉字那一侧是数字的词同理
    func testDigitHanBoundariesAreUntouched() {
        XCTAssertEqual(restored("大概 3 个人", "大概3个人。"), "大概3个人。")
        XCTAssertEqual(restored("买了 iPhone15 手机", "买了iPhone15手机。"), "买了 iPhone15手机。")
    }

    /// 同一个词出现两次、原文空格不一样：次数对得上就按顺序一一对应
    func testRepeatedWordFollowsRawOrder() {
        XCTAssertEqual(restored("App怎么装，打开 App 下载", "App怎么装？打开App下载。"),
                       "App怎么装？打开 App 下载。")
        // 次数对不上：只在原文每一次都带空格时才补
        XCTAssertEqual(restored("App怎么装，打开 App 下载", "打开App下载。"), "打开App下载。")
        XCTAssertEqual(restored("用 App 下载，打开 App 看", "打开App看。"), "打开 App 看。")
    }

    /// 阿语不是汉字，一律不碰；已有的空格一个都不删
    func testArabicAndExistingSpacesUntouched() {
        XCTAssertEqual(restored("ارسل لي ملف PDF من فضلك", "أرسل لي ملف PDF من فضلك."), "أرسل لي ملف PDF من فضلك.")
        XCTAssertEqual(restored("ملف PDFمن", "ملف PDFمن"), "ملف PDFمن")
        XCTAssertEqual(restored("这个 feature 的 demo", "这个 feature 的 demo。"), "这个 feature 的 demo。")
    }

    func testRestoreIsIdempotent() {
        let raw = "那个 QR code 怎么申请啊？打开 App Store 下载"
        let once = restored(raw, "QR code怎么申请？打开App Store下载。")
        XCTAssertEqual(once, "QR code 怎么申请？打开 App Store 下载。")
        XCTAssertEqual(restored(raw, once), once)
    }

    // MARK: - 提示词第 12 条

    /// 逐字取自 iOS `Prompts.swift`（2026-09-28）；Mac 两份提示词的条号（第 5 条同音、第 7 条数字）
    /// 与 iOS 一致，所以不用改号
    func testRule12IsInBothPrompts() {
        XCTAssertTrue(PolishService.systemPrompt().contains(
            "12. 两样照原文、不要「修」：中文与英文单词之间原有的空格不增不删（「打开 App Store 下载」不要写成「打开App Store下载」；数字与汉字之间仍按第 7 条）；人名不做同音替换——第 5 条的同音纠错不用在人名上，原文是哪个字就保留哪个字（「王总」不要改成「汪总」），除非词汇表给了这个名字的准确写法。"))
        XCTAssertTrue(PolishService.lightPrompt().contains(
            "【照原文】中文与英文单词之间原有的空格不增不删；人名不做同音替换——第 5 条的同音纠错不用在人名上，原文是哪个字就保留哪个字（「王总」不要改成「汪总」），除非词汇表给了这个名字的准确写法。"))
        // 示例刻意不用评测用例本身：评测测的是规则，不是抄例子
        for fixture in ["汉总", "韩总", "QR code", "滤芯"] {
            XCTAssertFalse(PolishService.systemPrompt().contains(fixture), fixture)
            XCTAssertFalse(PolishService.lightPrompt().contains(fixture), fixture)
        }
    }
}
