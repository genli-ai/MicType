import Foundation

// MARK: - 隐私与费用文案（唯一出处）

/// 「音频不出机 / 只发文字 / 不留存 / Key 在钥匙串 / 费用直付服务商 / 搜索按次计费」这六句话
/// 以前在关于页、引导欢迎页、引导结束页各写一遍，措辞还都不一样——用户读到三种说法，
/// 只能靠猜哪一句算数；改一次文案就得记得去另外两处同步，漏一处就自相矛盾（v4.0 调研 §1.12 / C10）。
///
/// 所以写成一处常量：**所有界面都引用这里的句子，不再各自造词**。
/// 三条硬约束：
///   • 必须是计算属性（`var` 而不是 `let`）——`tr()` 要在渲染时求值，否则切换界面语言不刷新；
///   • 句子刻意写短（一行装得下）：关于页与引导页都是固定高度，长句一换行就把下面的内容挤出窗口；
///   • 只陈述事实，不作承诺：每一句都对应一条能在代码里指出来的行为。
enum PrivacyCopy {

    /// 录音与识别全在本机（Qwen3-ASR / MLX）
    static var audioStaysLocal: String {
        tr("音频不出这台 Mac：录音与识别全在本机完成。",
           "Audio never leaves this Mac: recording and recognition run on-device.")
    }

    /// 只有文字出门，而且只在润色 / 指令开着时
    static var onlyTextLeaves: String {
        tr("开了润色或语音指令，只有识别出的文字发给你配置的服务商。",
           "With polish or voice commands on, only the recognized text goes to your provider.")
    }

    /// 请求显式带 store:false（OpenAI 默认会留 30 天日志，见调研 §1.9）
    static var noRetention: String {
        tr("请求带 store:false 发出，服务商不留存这些请求。",
           "Requests go out with store:false, so the provider keeps no copy.")
    }

    /// Key 只在钥匙串里：不进设置文件、不随导出走（SettingsBackup 从不导出 Key）
    static var keyInKeychain: String {
        tr("API Key 只存在 macOS 钥匙串里，不写进文件、也不随设置导出。",
           "Your API key lives in the macOS Keychain, never in a file or an export.")
    }

    /// 费用直付服务商：MicType 不代理请求
    static var youPayProvider: String {
        tr("费用直接结给服务商：MicType 不代理你的请求、不加价。",
           "You pay the provider directly; MicType never proxies your requests and never adds a markup.")
    }

    /// 联网搜索是显式付费开关，默认关（调研 §1.6：OpenAI 约 $10 / 1000 次）
    static var webSearchBilled: String {
        tr("联网搜索默认关闭，打开后由服务商按次计费（约每 1000 次 10 美元）。",
           "Web search is off by default; when on, the provider bills it per search (about $10 per 1,000).")
    }

    /// 数据流向那两句：讲"东西去了哪里"，引导第一屏用
    static var dataFlowLines: [String] { [audioStaysLocal, onlyTextLeaves] }

    /// Key 与费用那四句：讲"谁收你的钱、Key 放在哪"，引导结束屏用
    static var keyAndCostLines: [String] { [noRetention, keyInKeychain, youPayProvider, webSearchBilled] }

    /// 完整六句，顺序固定（关于页用）。顺序本身是文案的一部分：先说数据去哪，再说钱谁收
    static var allLines: [String] { dataFlowLines + keyAndCostLines }
}
