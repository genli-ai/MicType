import SwiftUI

// MARK: - 设置正页与引导第三屏共用的控件
//
// 为什么抽成一份：4.0.1 里引导第三屏把服务商选择器、接入地址框、模型下拉各抄了一遍，
// 两处很快就走散了。同一个决定只写一处，两处就不会走散（与 PrivacyCopy 同一条纪律）。
//
// 5.1.0 的版式（用户 2026-09-28 拍板：只留 OpenAI，设置页用户只做一件事——贴 Key）：
//
//   OpenAI Key  [••••••]  [去申请 Key ↗]                 ⓘ
//   已连通 ✓ 云端·OpenAI · gpt-transcribe · …   ← 状态行，只在有话说时出现
//
// 4.3.2 起的三条规矩照旧，改这一页之前先读：
//   • **没有段标题**。栏名由 SettingsFieldRow 摆在控件左边，一行只说一次。
//   • **ⓘ 只挂在真有细则的那一行**（API Key：存储、费用、联网搜索、Fast 档）。
//   • **常驻说明行只留"带着钱或隐私"的那种**；状态行不算说明：它只在真有话说时才出现。
//
// 5.1.0 删掉的：服务商分段选择器（ProviderPickerField）与「正在使用 ✓」、阿里云的
// 「API Host / 接入地址」输入框（QwenHostField）、引导 ③ 那两张服务商对比卡片（ProviderChoiceCards）。

/// 一行：栏名 + 控件 +（可选）那一行自己的 ⓘ。**设置窗口三页共用**（4.3.2 起）。
///
/// 为什么自己写而不用 Form 的 LabeledContent：这一串控件要在**两个容器**里长得一样——
/// 设置页是 Form(.grouped)，引导第二 / 三屏是 VStack。LabeledContent 的栏名宽度由容器算，
/// 两处对不齐；而"栏名宽度一致"正是这一版要的（用户嫌的就是排版乱）。
///
/// 栏名**不带冒号**：它是一列表头，不是一句话的开头。
struct SettingsFieldRow<Content: View>: View {
    let label: String
    var info: String? = nil
    @ViewBuilder var content: () -> Content

    /// 栏名那一列的宽度。**88 是被右边那一行顶住的上限**：识别模型那一行要摆
    /// 「Qwen3-ASR 0.6B 6-bit (recommended, fast) · ~862 MB」，112pt 时它当场被裁成 "· ~8…"。
    /// 所以英文栏名要写短（"Language" 而不是 "Recognition language"，
    /// "Overlay" 而不是 "Overlay position"）——栏名是一列表头，不是一句话。
    /// 改之前先拍一张快照看对齐与裁字（见 SettingsSnapshotTests）。
    static var labelWidth: CGFloat { 88 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: Self.labelWidth, alignment: .leading)
            // 控件占满剩下的宽度、靠左：ⓘ 因此永远落在行末同一条竖线上，
            // 不会因为这一行是个窄下拉就贴到下拉旁边去（各行 ⓘ 忽左忽右）
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let info = info { InfoButton(info) }
        }
    }
}

/// 一行开关 + 它自己的那颗 ⓘ（「实时草稿」「保存听写历史」共用这一个）。
///
/// 开关自带栏名，所以不走 SettingsFieldRow 那条"栏名列"——它要的是"标签在左、开关靠右"，
/// 而那正是 Toggle 在 Form 里的默认长相。这里只负责把 ⓘ 接在最右边。
struct SettingsToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var info: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Toggle(label, isOn: $isOn)
            if let info = info { InfoButton(info) }
        }
    }
}

// ModelPickerField（「模型」下拉）与 CloudRecognitionFields（「识别也用云端」开关 + 那次检查）
// 5.0.0 整段删掉：型号写死平衡档、识别永远云端，两个控件问的都是没有第二个答案的问题。
// 那次「拨开开关就当场测一次」的检查也跟着没了——粘 Key 那一下验的就是同一条链路
// （KeyEntryView 的 .cloudASR 探针），一个动作管到底。

// MARK: - 首配那一串控件（设置正页与引导 ③ 同一份）

/// OpenAI Key + 那一行状态。两处共用，只是外面包着的东西不同：
///   • **设置正页**（`.settings`）：Key 框右边带「去申请 Key ↗」；
///   • **引导 ③**（`.onboarding`）：上面是**申请 Key 的三步**（首配最容易卡死人的一分钟
///     就是"去哪儿点、怎么拿到 Key"），第 3 步已经直达 API Key 页，所以 Key 框右边不再摆那颗按钮。
/// 「服务商 OpenAI」那一行只读的 5.1.0 首版加过、同日删掉（用户 2026-09-28）：栏名「OpenAI Key」已经说了。
///
/// 5.1.0 之前这里还收着服务商选择器、阿里云的接入地址框和"看着的那一档验证通过才采纳"那一套；
/// 只剩一家之后，这些都没有第二个答案了。
///
/// 5.3.0 引导 ②（设计稿 Onboarding-2）：顺序倒过来——**大框在上、三步在下**。
/// 那一屏的标题已经是「贴上你的 OpenAI Key」，要做的事就是那个框；三步是给还没有 Key 的人的。
struct CloudSetupCore<Notices: View>: View {

    /// 摆成 Form 的分段（设置页），还是摆成一串行（引导 ② 那一屏是 VStack）
    enum Style { case settings, onboarding }

    let style: Style
    var onKeyStatus: ((KeyVerifier.Status) -> Void)? = nil
    /// 引导 ②：这一屏出现时从剪贴板认出来的 Key（见 ClipboardKey）。设置页永远 nil
    var prefill: String? = nil
    /// Key 上面的边界状态（例如 OpenAI 的地址被改过）。正常情况下一个字都不显示
    @ViewBuilder var notices: () -> Notices

    /// 唯一的一档
    private let provider: LLMProvider = .openai

    var body: some View {
        switch style {
        case .settings: settingsSection
        case .onboarding: onboardingRows
        }
    }

    // MARK: 设置正页：一张卡片装完

    @ViewBuilder
    private var settingsSection: some View {
        Section {
            notices()
            keyField
        }
    }

    // MARK: 引导 ②：大框 + 申请步骤

    @ViewBuilder
    private var onboardingRows: some View {
        notices()
        keyField
        ConsoleStepsView(provider: provider)
            .padding(.top, 14)
    }

    // MARK: 控件本体

    /// 验通之后那一行末尾还要补什么。**两处补的不是同一个单位**，因为两处的人在问不同的问题：
    ///   • 设置页：「一小时大概花多少」（他已经在用了，关心的是月底账单）；
    ///   • 引导 ②：「我说一句话要多少钱」（他还没用过，一小时对他没有概念）。
    /// 两个数都从 LLMCatalog 同一套单价算出来（那是全 App 唯一的价格出处）。
    private var connectedNote: String {
        switch style {
        case .settings: return SettingsCopy.connectedCost(provider: provider)
        case .onboarding: return LLMCatalog.perSentenceCostNote(provider: provider)
        }
    }

    /// Key 验证**一律打识别端点**（5.0.0 起识别也在云端，那条链路更严）：验通了就是三件事全通。
    private var keyField: some View {
        KeyEntryView(provider: provider, model: LLMCatalog.polishDefault(for: provider),
                     probe: .cloudASR(.openai),
                     connectedNote: connectedNote,
                     showsConsoleLink: style == .settings,
                     onStatusChange: { status in onKeyStatus?(status) },
                     layout: style == .onboarding ? .hero : .row,
                     prefill: style == .onboarding ? prefill : nil)
    }
}

// MARK: - 申请步骤（引导 ② 下半）

/// 编号一行一步，右边跟着能直接打开那一页的链接。文字与链接的唯一出处是
/// `LLMCatalog.consoleSteps(for:)`——这里只负责摆。
///
/// 为什么值一个组件：这是**整个产品最容易卡死人的一分钟**。用户手上没有 Key，
/// 而"去哪儿点"这件事我们知道、他不知道；写成一句"去服务商控制台申请一把 Key"
/// 等于把最难的一步留给他自己。
///
/// 5.3.0 的长相（设计稿 Onboarding-2）：编号装进一枚 18 pt 的细圈里，正文 13 pt，
/// 链接「打开 ↗」用强调色的单色字（渐变在小字上读不清，见 Theme.accentText）。
struct ConsoleStepsView: View {
    let provider: LLMProvider
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Theme.palette(scheme)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(LLMCatalog.consoleSteps(for: provider).enumerated()), id: \.offset) { pair in
                HStack(alignment: .center, spacing: 10) {
                    Text("\(pair.offset + 1)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(palette.muted)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(scheme == .dark ? Color.white.opacity(0.18)
                                                                 : Color.black.opacity(0.15),
                                                 lineWidth: 1))
                    Text(pair.element.text)
                        .font(.system(size: 13))
                        .foregroundColor(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    ForEach(pair.element.links, id: \.url) { link in
                        Button(link.label + " ↗") { open(link.url) }
                            .buttonStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(scheme == .dark ? Theme.accentText : Theme.accentA)
                            .fixedSize()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func open(_ url: String) {
        guard let target = URL(string: url) else { return }
        Log.info("Onboarding opened console step host=\(target.host ?? "?")")
        NSWorkspace.shared.open(target)
    }
}
