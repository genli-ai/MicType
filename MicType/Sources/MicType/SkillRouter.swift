import Foundation

// MARK: - 语音技能路由（V3）
// 意图区分靠手势而不靠内容：轻点 = 纯输入（永不解析指令），按住 = 指令模式。
// 指令模式内部：显式回复触发词是直通捷径（说了必走"起草回复"这条专用提示词）；
// 其余有选区的指令走通用入口（见 AgentService.runOnSelection）。
// **结果往哪儿送不由这里、也不由模型决定**（5.0.1）：两条路都按「选区能不能被原地改写」
// 这一条确定性规则投递（DictationController.selectionDelivery）。

enum SkillRouter {

    /// 指令是否为显式"帮我回复"类（直通回复草拟，不交给模型判意图）
    static func isReplyTrigger(_ text: String) -> Bool {
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
            .lowercased()
        let triggers = ["帮我回复", "帮我回一下", "帮我回个", "帮我回他", "帮我回她", "帮我答复",
                        "你帮我回复", "回复他", "回复她", "回复这个", "回复一下", "回复对方",
                        "helpmereply", "draftareply", "replyto"]
        return triggers.contains { compact.hasPrefix($0) }
    }
}
