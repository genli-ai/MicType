import SwiftUI

// MARK: - 「云端 AI」页与引导第三屏共用的控件
//
// 为什么抽成一份：4.0.1 里引导第三屏把服务商选择器、接入地址框、模型下拉各抄了一遍，
// 于是阿里云那个「识别也用云端」开关只长在设置页上——在引导里选了阿里云的人根本看不到它，
// 也就没人告诉他云端识别是可选的、要花钱的。同一个决定只写一处，两处就不会走散
// （与 QwenHostField、PrivacyCopy 同一条纪律）。
//
// 4.3.2 的版式（用户 2026-09-22：「API host 为什么是一个 optional，下面写的 only this host
// 又是什么……这个 settings 设计还是太冗余，把这个简化」）：
//
//   使用方式   [只用本地 | 本地 + AI]
//   ┌ 服务商   [OpenAI | DeepSeek | 阿里云]   正在使用 ✓
//   │ API Key  [••••••]  [去申请 Key ↗]                    ⓘ
//   │ API Host [百炼控制台里的接入地址]        ← 只有阿里云这一档
//   └ 模型     [qwen3.8-flash · 快（默认） ▾]
//   ┌ 识别也用云端                            [开关]       ⓘ
//   │ qwen3-asr-flash-realtime · 边说边上传 · 约 $0.13/小时
//   │ 语音指令允许联网搜索                    [开关]       ⓘ
//   └ 联网搜索按服务商自己的价目计费，默认开启。
//
// 三条规矩，改这一页之前先读：
//   • **没有段标题**。4.3.1 之前每一段都是「段标题 + ⓘ」再跟一行「栏名：控件」，
//     而段标题和栏名说的是同一件事（「服务商」上面写一遍、下面再写一遍）。现在栏名
//     由 SettingsFieldRow 摆在控件左边，一行只说一次。
//   • **ⓘ 只剩三颗**：API Key、识别也用云端、联网搜索。其余几段的细则要么已经被状态行
//     说掉了（「正在使用 ✓」「预览中，仍用 X」），要么并进了 Key 那一颗。
//   • **常驻说明行只留"带着钱或隐私"的那两行**（云端识别的单价、联网搜索的计费）。
//     状态行不算说明：它只在真有话说时才出现。

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

/// 一行开关 + 它自己的那颗 ⓘ（云端识别、联网搜索、输入页那几个开关共用这一个）。
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

/// 阿里云那一档的「接入地址（可选）」输入框（设置页与引导页共用这一个）。
///
/// 来历：4.1.4 把它删了（那时的理由是"大多数人看不懂、填错了表现为鉴权失败"），
/// 4.3.1 按用户 2026-09-21 的要求加回来。理由是那天的实测——百炼控制台 API Key 页上
/// 明写着一条「接入地址（apiHost）」，那一条对话 / 同步识别 / 实时 WebSocket 三样全通，
/// 而自动探测落到了另一台（Key 里 `sk-ws-` 后面那一段与业务空间 ID 并不相同）。
/// 两者都不算错，但**用户要能把控制台上那一条原样填进来**。
///
/// 三条规矩：
///   • 空着是常态 = 自动探测，一个字都不变；
///   • 填了就**只用这一台**（润色 / 指令、同步识别、实时 WebSocket 全走它），
///     不探测、不被每周复查换掉、失败也不替他换；
///   • 拼不出主机名的输入当场提示，**照常按"没填"处理，但一个字都不删**。
///
/// 改完要重新验证：提交（回车 / 失焦 / 停手 0.8 秒）之后，这一栏把 tick 推给 KeyEntryView，
/// 那边拿同一把 Key 对着新地址重跑一次验证——那是整页唯一的手动测试，结果仍显示在 Key 的状态行。
struct QwenHostField: View {
    /// 地址提交了（真的写回了设置）。调用方据此触发重新验证。
    var onCommit: () -> Void = {}

    @AppStorage(SettingsKeys.qwenAPIHost) private var storedHost = ""
    /// 输入框里这一刻的字。**不直接绑 @AppStorage**：那样每敲一个字母都会落盘一次，
    /// 而落盘就意味着候选表当场变成"一台半截主机名"，日志里全是拼到一半的地址。
    @State private var text = ""
    @State private var commitWork: DispatchWorkItem?
    @FocusState private var focused: Bool

    /// 停手多久算"填完了"。0.8 秒是抄 Key 那一栏的经验：再短会在手打中途触发一次验证，
    /// 再长会让人以为这一栏没反应（它没有「确定」按钮）。
    private static let settleDelay: TimeInterval = 0.8

    var body: some View {
        // 栏名只写 "API Host"，**不写「（可选）」**：一栏东西是不是可选，看它空着能不能用就知道了，
        // 写在栏名里只是把每一行都拉长（用户 2026-09-22 点名了这两个字）。
        // 去哪儿找这一串写在占位文字里，不再单起一行说明。
        SettingsFieldRow(label: "API Host") {
            TextField(text: $text,
                      prompt: Text(tr("百炼控制台里的接入地址",
                                      "API host from the Model Studio console"))) {
                Text("API Host")
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { commit() }
            .onAppear { text = storedHost }
            // 别处改了它（导入设置文件、别的窗口）：跟上，但别把正在敲的字顶掉
            .onChange(of: storedHost) { _, newValue in
                guard !focused, newValue != text else { return }
                text = newValue
            }
            .onChange(of: text) { _, _ in scheduleCommit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
        }
        // **只在出问题时才有字**（4.3.2）：留空要自动探测、填了只用这一台——这两件事
        // 由行为本身说，不再各占一行解释。填了个不像主机名的串才必须当场说，
        // 否则他会以为自己已经把地址定下来了。
        if AlibabaEndpoint.storedHostIsJunk(text) {
            // **不删、不清空**，只说它现在不算数（用户 2026-09-21：上次填了什么就保持什么）
            Caption(SettingsCopy.hostMalformed, warning: true)
        }
    }

    /// 停手 0.8 秒就当填完了（没有「确定」按钮，所以必须自己判）
    private func scheduleCommit() {
        commitWork?.cancel()
        let work = DispatchWorkItem { commit() }
        commitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// 写回设置。**只有真的变了才写、才重新验证**——失焦事件每次切页都来一发，
    /// 每来一发就重验一次的话，用户会看到状态行无缘无故闪一下。
    private func commit() {
        commitWork?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != storedHost else { return }
        let before = AlibabaEndpoint.normalizeHost(storedHost)
        storedHost = trimmed
        Log.info("Qwen host field set to=" + (trimmed.isEmpty ? "auto"
                                              : AlibabaEndpoint.redacted(trimmed)))
        // 归一之后还是同一台（补了个 https:// 之类）就不必重验：那一趟要花几秒和几个 token
        guard AlibabaEndpoint.normalizeHost(trimmed) != before else { return }
        onCommit()
    }
}

/// 服务商分段选择器 +「正在使用 ✓」。
///
/// 换档之后要做什么**不写在这里**：4.1.1 起两处是同一条语义——看着的那一档，
/// **验证通过（钥匙串里有 Key）才采纳**（AISetup.adoptsProvider），在那之前选择器只是预览。
/// 具体怎么写回设置仍由调用方的 Binding setter 决定。
///
/// 那枚小标签是这次改动的要害（用户 2026-09-20 的实测反馈）：三档并排、每一档都点得动，
/// 而屏幕上没有任何地方写着"现在真正在用的是哪一家"——于是人人挨个点一遍，停在哪档算哪档。
struct ProviderPickerField: View {
    @Binding var selection: LLMProvider
    /// 摆出来的那几档（调用方负责把"他正在用的那一档"也带上，否则选择器会是空白的）
    let offered: [LLMProvider]
    /// 这一刻**真正生效**的那一档（Settings.llmProvider）
    let inUse: LLMProvider
    /// 看着的这一档在钥匙串里有没有 Key。false 且它不是生效那档 = 现在只是预览。
    /// 引导页传 false（它下面那行 providerNotAdoptedYet 把同一件事说得更全），
    /// 免得同一个状态并排出现两行。
    var showsNotSetUpHint: Bool = false

    var body: some View {
        // 这一行没有 ⓘ（4.3.2）：原来那颗里讲的「验证通过才真的换过去」，
        // 现在由右边那枚「正在使用 ✓」和下面那行「预览中，仍用 X」当场说掉了。
        SettingsFieldRow(label: tr("服务商", "Provider")) {
            Picker("", selection: $selection) {
                ForEach(offered, id: \.rawValue) { provider in
                    Text(provider.segmentName).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            if selection == inUse {
                Text(SettingsCopy.providerInUse)
                    .font(.caption)
                    .foregroundColor(.green)
                    .fixedSize()
            }
        }
        if showsNotSetUpHint, selection != inUse {
            // 这一刻「正在使用 ✓」不在屏幕上（它只长在生效那一段旁边），所以这行字
            // 必须自己把生效那家的名字念出来
            Caption(SettingsCopy.providerNotSetUp(current: inUse.segmentName))
        }
    }
}

// ModelPickerField（「模型」下拉）与 CloudRecognitionFields（「识别也用云端」开关 + 那次检查）
// 5.0.0 整段删掉：型号写死平衡档、识别永远云端，两个控件问的都是没有第二个答案的问题。
// 那次「拨开开关就当场测一次」的检查也跟着没了——粘 Key 那一下验的就是同一条链路
// （KeyEntryView 的 .cloudASR 探针），一个动作管到底。

// MARK: - 首配那一串控件（设置正页与引导 ③ 同一份）

/// API Key +（阿里云的）接入地址 + 那一行状态。两处共用，只是外面包着的东西不同：
///   • **设置正页**（`.settings`）：上面多一行服务商分段选择器；
///   • **引导 ③**（`.onboarding`）：服务商由上面两张卡片选（HowYouUsePage），
///     这里换成**那一家的申请步骤**——首配最容易卡死人的一分钟就是"去哪儿点、怎么拿到 Key"。
///
/// 为什么非得共用到这一层：4.0.1 两处各写一份，于是阿里云那个接入地址框只长在设置页上。
/// 现在连顺序、标题、那颗 ⓘ 都收进这一个视图，两处只剩下真正不同的那一点：
/// Binding 的 setter（各自决定换档之后要清什么、要刷新什么）。
struct CloudSetupCore<ProviderNotices: View>: View {

    /// 摆成 Form 的分段（设置页），还是摆成一串行（引导 ③ 那一屏是 VStack）
    enum Style { case settings, onboarding }

    let style: Style
    /// 这一刻看着的那一档（可能还没被采纳为生效服务商）
    let selected: LLMProvider
    /// 这一刻**真正生效**的那一档（Settings.llmProvider）：选择器旁边那枚「正在使用 ✓」靠它
    let inUse: LLMProvider
    let provider: Binding<LLMProvider>
    /// 选择器下面要不要那行「预览中，仍用 X」。引导 ③ 传 false：那一屏的卡片自己带选中态，
    /// 而且它下面那行 providerNotAdoptedYet 把同一件事说得更全
    var showsNotSetUpHint: Bool = false
    var onKeyStatus: ((KeyVerifier.Status) -> Void)? = nil
    /// 「服务商」下面的边界状态（地址被改过、这一档还没 Key……）
    @ViewBuilder var providerNotices: () -> ProviderNotices

    /// 「接入地址」那一栏刚被改过的次数。推给 KeyEntryView，让它拿同一把 Key 对着新地址
    /// 重验一次——**那是整页唯一的手动测试**，所以结果仍然显示在 Key 的状态行上。
    @State private var hostChangeTick = 0

    /// 摆出来的那两档。**永远是全部两家**（5.0.0 起没有"他在用一个列表外的档"这回事了）。
    private var offered: [LLMProvider] { LLMProvider.allCases }

    var body: some View {
        switch style {
        case .settings: settingsSections
        case .onboarding: onboardingRows
        }
    }

    // MARK: 设置正页：一张卡片装完

    @ViewBuilder
    private var settingsSections: some View {
        // 一张卡片装完"发给谁"：服务商 / API Key /（阿里云的）API Host。
        // **没有段标题**——每一行自己带栏名（见文件头那张图）
        Section {
            ProviderPickerField(selection: provider, offered: offered,
                                inUse: inUse, showsNotSetUpHint: showsNotSetUpHint)
            providerNotices()
            keyField
            // 「API Host」只在阿里云这一档出现：只有百炼的控制台会给你一条 apiHost，
            // OpenAI 的地址是固定的，摆一个永远该留空的框只会让人以为自己漏填了
            if showsHostField { hostField }
        }
    }

    // MARK: 引导 ③：申请步骤 + 同样那两个框

    @ViewBuilder
    private var onboardingRows: some View {
        providerNotices()
        ConsoleStepsView(provider: selected)
        keyField
        if showsHostField { hostField }
    }

    // MARK: 控件本体（两种摆法共用这两个）

    /// 只有阿里云有「接入地址」这回事（见 QwenHostField 的注释）
    private var showsHostField: Bool { selected == .qwen }

    private var hostField: some View {
        QwenHostField(onCommit: { hostChangeTick &+= 1 })
    }

    /// Key 验证走哪条链路：**一律打识别端点**（5.0.0 起识别也在云端，而那条链路更严——
    /// 阿里云的实测里工作空间主机在对话侧 200、在识别侧 403）。验通了就是三件事全通。
    private var keyProbe: KeyVerifier.Probe {
        .cloudASR(selected == .qwen ? .alibaba : .openai)
    }

    /// 验通之后那一行末尾还要补什么。**两处补的不是同一个单位**，因为两处的人在问不同的问题：
    ///   • 设置页：「我这一档一小时大概花多少」（他已经在用了，关心的是月底账单）；
    ///   • 引导 ③：「我说一句话要多少钱」（他还没用过，一小时对他没有概念）。
    /// 两个数都从 LLMCatalog 同一套单价算出来（那是全 App 唯一的价格出处）。
    private var connectedNote: String {
        switch style {
        case .settings: return SettingsCopy.connectedCost(provider: selected)
        case .onboarding: return LLMCatalog.perSentenceCostNote(provider: selected)
        }
    }

    private var keyField: some View {
        KeyEntryView(provider: selected, model: LLMCatalog.defaultModel(for: selected),
                     probe: keyProbe,
                     hostChangeTick: hostChangeTick,
                     connectedNote: connectedNote,
                     onStatusChange: { status in onKeyStatus?(status) })
    }
}

// MARK: - 申请步骤（引导 ③ 下半）

/// 编号一行一步，右边跟着能直接打开那一页的按钮。文字与链接的唯一出处是
/// `LLMCatalog.consoleSteps(for:)`——这里只负责摆。
///
/// 为什么值一个组件：这是**整个产品最容易卡死人的一分钟**。用户手上没有 Key，
/// 而"去哪儿点"这件事我们知道、他不知道；写成一句"去服务商控制台申请一把 Key"
/// 等于把最难的一步留给他自己。
struct ConsoleStepsView: View {
    let provider: LLMProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(LLMCatalog.consoleSteps(for: provider).enumerated()), id: \.offset) { pair in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // 编号用文字而不是列表符号：它要和右边那颗「打开」按钮在同一条基线上
                    Text("\(pair.offset + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 16, alignment: .trailing)
                    Text(pair.element.text)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    ForEach(pair.element.links, id: \.url) { link in
                        Button(link.label + " ↗") { open(link.url) }
                            .buttonStyle(.link)
                            .font(.caption)
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

// MARK: - 引导 ③ 上半：两张并排的服务商卡片

/// 每张三行：**每小时多少钱 / 适合谁 / 一句优势**。三行都从 LLMCatalog 取
/// （价格是算出来的，不写死）。
///
/// 为什么是卡片而不是设置页那个分段选择器：这一刻用户对这两个名字**一无所知**，
/// 而他要做的不是"换一档看看"，是第一次做一个会花他自己的钱的选择。
/// 一个只有两个词的分段选择器给不了他任何做这个选择的依据。
struct ProviderChoiceCards: View {
    @Binding var selection: LLMProvider
    /// 这一刻**真正生效**的那一档：验证通过之后卡片上要出现「正在使用 ✓」
    let inUse: LLMProvider

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(LLMProvider.allCases, id: \.rawValue) { provider in
                card(provider)
            }
        }
    }

    private func card(_ provider: LLMProvider) -> some View {
        let picked = provider == selection
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(provider.segmentName)
                    .font(.system(size: 13, weight: .semibold))
                if provider == inUse {
                    Text(SettingsCopy.providerInUse)
                        .font(.caption2)
                        .foregroundColor(.green)
                }
                Spacer(minLength: 0)
            }
            // 价钱排在第一行：它是这两张卡片之间最大的差别（五倍）
            Text(LLMCatalog.hourlyCostNote(provider: provider))
                .font(.caption)
            Text(LLMCatalog.audienceNote(provider: provider))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(LLMCatalog.strengthNote(provider: provider))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(picked ? 0.14 : 0))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(picked ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: picked ? 1.5 : 1)))
        .contentShape(Rectangle())
        .onTapGesture { selection = provider }
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(provider.segmentName)
    }
}
