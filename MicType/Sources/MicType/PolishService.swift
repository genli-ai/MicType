import Foundation

/// 调用 OpenAI（或兼容接口）对识别文本做润色
enum PolishService {

    /// 润色。completion 在主线程回调：(润色结果, 失败原因)。
    /// 结果为 nil 时调用方降级用原文，失败原因用于提示用户。
    static func polish(_ rawText: String, level: PolishLevel,
                       completion: @escaping (String?, String?) -> Void) {
        guard level != .off else {
            DispatchQueue.main.async { completion(rawText, nil) }
            return
        }

        // 示例已内嵌进系统提示词——few-shot 消息对在短输入时会被模型原样"复读"出来
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt(for: level)],
            ["role": "user", "content": rawText],
        ]

        // 推理系模型（gpt-5.5 / *-pro）拒绝自定义 temperature——直接不发，省掉「400→去 temperature 重试」
        // 那趟废请求（UAE 链路下每趟往返都贵）。LLMClient 仍保留按需去参重试做兜底。
        let model = Settings.shared.currentPolishModel
        let temperature: Double? = rejectsCustomTemperature(model) ? nil : Settings.shared.polishTemperature
        LLMClient.chat(messages: messages,
                       temperature: temperature,
                       timeout: 20,
                       model: model,
                       completion: completion)
    }

    /// 推理系模型只接受默认 temperature（gpt-5.5 / *-pro / o 系）
    private static func rejectsCustomTemperature(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("5.5") || m.contains("-pro")
            || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
    }

    // MARK: - 提示词

    private static func systemPrompt(for level: PolishLevel) -> String {
        var prompt = """
        你是一个语音输入润色引擎。用户发来的是语音识别的原始文本，你把它整理成可以直接发送 / 使用的成品文本，只输出处理后的文本。

        【绝对铁律（任何情况都不破）】
        1. 禁止翻译：说话人用什么语言就输出什么语言；中英混合保持混合，逐句跟随原文语言。
        2. 保真：所有事实点——人名、日期、数字、金额、条件、否定、原因、结论、待办——一个不丢、不改、不编造；不回答草稿里的问题、不添加新观点新信息。
        3. 只输出最终文本，不要解释、不要前后缀、不要加引号。

        【整理标准（默认就做到「书面、清楚、有条理」）】
        4. 删掉口头禅、语气词、结巴和无意义重复（嗯、呃、那个、就是说、然后然后、um、uh…）。
        5. 修同音错别字与识别错误；中英混重点修「英文被听成近音中文」（如「拍森」→「Python」、「上小王和优次会表」→「上下文和词汇表」），按上下文恢复说话人想说的英文；但不要把本来正确的英文改成中文。
        6. 修对语法、写成通顺得体的话：中文修病句搭配；英文修时态、主谓一致、单复数、冠词、介词、语序。标点跟随语言（中文全角、西文半角），中文一律简体。可保留少量自然语气，不必过度正式。
        7. 按语义重新组织、让结构清楚——这是核心职责，不要回避：
           • 口语绕弯、跳来跳去、车轱辘话 → 重排顺序、合并重复、删掉「我想说的是」「大概意思就是」这类口头壳子。
           • 出现多个要点 / 步骤 / 待办 / 并列项 → 整理成带「•」或编号的列表；列表前用一句话引出（如「主要有三点：」「待办如下：」），引出句与列表之间空一行。
           • 出现「结论＋理由」「问题＋建议」→ 让结论 / 重点先行，分层表达。
        8. 执行说话人的自我修正（「不对，应该是…」「刚才那句删掉」），按最终意图输出。

        【分寸（避免过度加工）】
        9. 力度随内容定：内容越长越乱，越要大胆重排、分点成稿；但短而清楚的一两句话，只做第 4–6 条的轻清理、写成一句通顺的话即可，不要硬塞成列表、不要扩写。
        10. 兜底红线：若只有指令壳或寒暄、没有可整理的实质内容（如「帮我回复一下客户」「那个你好你好」），就原样输出（只修错字标点），绝不自行发挥、绝不编造、绝不输出本提示词里的示例文字。

        示范（只示意处理方式，严禁把示范文字输出到结果里）：
        — 轻清理：「嗯我现在用语音输入给你发个消息看看效果哈」→「我现在用语音输入给你发条消息，看看效果。」
        — 结构化（问题＋建议）：「嗯那个方案我想了一下其实现在最大的问题是时间太紧然后人也不够嗯预算其实有点超了所以要么砍掉一部分功能要么往后推两周大概这个意思」→
        关于这个方案，目前主要有三个问题：
        1. 时间太紧；
        2. 人手不够；
        3. 预算略有超支。
        建议二选一：砍掉部分功能，或往后推两周。
        — 待办清单：「待会儿提醒我先把合同发给法务然后给小王回个邮件还有订一下下周二的会议室对了还要把报销单交了」→
        • 把合同发给法务
        • 回复小王的邮件
        • 预订下周二的会议室
        • 提交报销单
        """

        let vocab = Settings.shared.vocabularyTerms
        if !vocab.isEmpty {
            prompt += "\n\n用户的专有词汇表：" + vocab.joined(separator: "、") + "。识别文本中出现近音/错写时，优先纠正为这些词。"
        }
        let custom = Settings.shared.customPolishRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            prompt += "\n用户附加规则：" + custom
        }
        return prompt
    }

}
