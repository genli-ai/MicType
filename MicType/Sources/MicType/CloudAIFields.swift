import SwiftUI

// MARK: - 「云端 AI」页与引导第三屏共用的控件
//
// 为什么抽成一份：4.0.1 里引导第三屏把服务商选择器、接入地址框、模型下拉各抄了一遍，
// 于是阿里云那个「识别也用云端」开关只长在设置页上——在引导里选了阿里云的人根本看不到它，
// 也就没人告诉他云端识别是可选的、要花钱的。同一个决定只写一处，两处就不会走散
// （与 QwenHostField、PrivacyCopy 同一条纪律）。

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
        TextField(tr("接入地址（可选）", "API host (optional)"), text: $text)
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
        // 控件旁边**永远只有一行**（Plan C 的预算）：填错了说错在哪，否则空着说默认、
        // 填了说代价。三句话互斥，不叠着摆。
        if AlibabaEndpoint.storedHostIsJunk(text) {
            // **不删、不清空**，只说它现在不算数（用户 2026-09-21：上次填了什么就保持什么）
            Caption(SettingsCopy.hostMalformed, warning: true)
        } else {
            Caption(AlibabaEndpoint.normalizeHost(text) == nil
                    ? SettingsCopy.hostAutoDetected : SettingsCopy.hostPinned)
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
        HStack(spacing: 8) {
            Picker(tr("服务商：", "Provider:"), selection: $selection) {
                ForEach(offered, id: \.rawValue) { provider in
                    Text(provider.segmentName).tag(provider)
                }
            }
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

/// 「模型」下拉：一个决定同时写回润色与指令两个型号字段。
/// 4.1.1 起**没有"分开设"这条路了**（用户 2026-09-20 拍板：润色和指令全部同一个），
/// 所以这两个字段从此只由这一个下拉写，「高级」里那两个输入框已经拿掉。
struct ModelPickerField: View {
    let provider: LLMProvider
    @Binding var polishModel: String
    @Binding var commandModel: String
    /// 下拉停在「自定义…」那一项上。只影响这一页怎么显示，不落盘——落盘的永远是型号名本身。
    @Binding var customChosen: Bool

    private var menu: [LLMCatalog.ModelChoice] { LLMCatalog.modelMenu(for: provider) }

    /// 下拉 ←→ 两个型号字段。读是"现在落在选单的哪一项上"，写是"把两个字段一起改掉"。
    /// 两个字段不一样（4.1.0 之前分开设过、或导入了这样一份设置）时如实显示「自定义…」，
    /// 绝不把用户钉回某一项——启动时那条一次性迁移会把它们拉回同一个值。
    private var selection: Binding<String> {
        Binding(get: {
                    guard !customChosen else { return "" }
                    return LLMCatalog.selectedMenuModel(provider: provider,
                                                        polish: polishModel,
                                                        command: commandModel) ?? ""
                },
                set: { newValue in
                    guard !newValue.isEmpty else {
                        // 选了「自定义…」：只是把输入框露出来，一个字段都别动
                        customChosen = true
                        return
                    }
                    customChosen = false
                    polishModel = newValue
                    commandModel = newValue
                    Log.info("Model set provider=\(provider.rawValue) model=\(newValue)")
                })
    }

    /// 「自定义…」下面那个输入框：填什么，润色和指令就都用什么。
    /// 手打出来的名字正好是选单里的某一项时，下拉自己跳回那一项——不然屏幕上会出现
    /// 「自定义… / gpt-5.6-sol」这种自相矛盾的一对。
    private var customText: Binding<String> {
        Binding(get: { polishModel },
                set: { newValue in
                    polishModel = newValue
                    commandModel = newValue
                    if menu.contains(where: {
                        $0.id == newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }) {
                        customChosen = false
                    }
                })
    }

    var body: some View {
        Group {
            if menu.isEmpty {
                // 其他 OpenAI 兼容服务 / 本机模型没有内置型号（型号名只有用户自己知道）：
                // 下拉整个藏掉，指路「高级」里那两个输入框，而不是摆一个点了没反应的控件
                Caption(SettingsCopy.modelNameInAdvanced)
            } else {
                Picker(tr("模型：", "Model:"), selection: selection) {
                    ForEach(menu, id: \.id) { choice in
                        Text(LLMCatalog.modelLabel(choice)).tag(choice.id)
                    }
                    // 空串 = 「自定义…」：用户自己填型号名，或者他在「高级」里把润色和指令分开设过了
                    Text(tr("自定义…", "Custom…")).tag("")
                }
                if selection.wrappedValue.isEmpty {
                    TextField(tr("型号名", "Model name"), text: customText)
                        .textFieldStyle(.roundedBorder)
                }
                // 下拉下面唯一那一行：这一个选择管到哪儿。型号名不在这句话里重复
                // （下拉自己写着它），型号各是什么来头收进段头那颗 ⓘ
                Caption(SettingsCopy.modelUsedForBoth)
            }
        }
    }
}

/// 「识别也用云端」开关 + 一行代价 + 一行结论。**整段只有这三行。**
///
/// 4.2.2 起**阿里云与 OpenAI 两家都有**（OpenAI 的实时转写端点实测可用，而且它认词汇表
/// 热词）；DeepSeek 没有识别接口，把 Base URL 指向第三方网关的 OpenAI 档也没有
/// （实时地址是写死的官方域名，见 CloudASRSettings.openAIUsesOfficialEndpoint）。
/// 开关本身只写一条设置（识别引擎），判据走 AISetup.engine（纯函数，单测钉死）。
///
/// 两家的代价差着近八倍（阿里云约 $0.13/小时、OpenAI 约 $1/小时），所以单价必须写在
/// 开关旁边——出处只有 LLMCatalog.cloudASRPriceNote 一个。
///
/// 4.1.4 把这一段上的**所有**接入地址与测试控件都收掉了（用户 2026-09-20 实测后拍板：
/// 「三个东西要测，太复杂」「永远别让用户去碰接入地址」）：
///   • **「接入地址（可选）」输入框**——见 KeyEntryView 末尾那段注释；
///   • **「测试识别」按钮**——把开关拨开本来就是"我要用它"，那一刻自己去测一次就好。
///     测不通就把开关拨回去：**开着的开关必须意味着它真的能用**，否则用户以为配好了，
///     直到某一次听写才发现每段录音都白传了一趟；
///   • **「已试通的接入地址 + 重新探测」那一行**——主机名对用户毫无意义，而那颗按钮是
///     第三个"要点一下试试"的东西。它唯一不可替代的用途（强制重挑一台）改由
///     AlibabaFastestHostRefresh 每周自动做一次，外加每次验证 Key / 失败恢复都顺带做掉。
struct CloudRecognitionFields: View {
    /// Key 验证通过的次数。**一个动作管到底**：验一次 Key，开着的云端识别就跟着重测一次，
    /// 用户不必再去找第二颗按钮（4.1.4 起那颗按钮也确实没有了）。
    var keyVerifiedTick: Int = 0
    /// 开关动过之后调用方要做的事（引导页据此重算"AI 现在跑不跑得起来"）
    var onEngineChange: (() -> Void)? = nil
    /// 这一段属于哪一家。**由调用方传**：它同时是"看着的"和"生效的"那一档
    /// （showsCloudRecognition 已经保证两者相同），这里不再自己去读设置。
    var provider: LLMProvider = .qwen

    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue
    /// 开关记的是**意愿**，不是当前引擎（4.3.1 起，用户 2026-09-21 拍板）：
    /// 换服务商不再把它抹掉，实际走哪一档由 AISetup.engine 推出来。
    @AppStorage(SettingsKeys.cloudRecognitionWanted) private var cloudRecognitionWanted = false

    /// 拨开开关那一刻自动跑的那次检查（一次性快照）
    @State private var checking = false
    @State private var checkResult = ""
    @State private var checkOK = false
    /// 这一行结论属于哪一次配置。探针要跑几秒到几分钟（阿里云超时 120s），期间用户完全可以
    /// 把开关拨回去、换一把 Key——回来的那条旧结论绝不能落在新配置下面。
    @State private var checkGeneration = 0

    /// 这一家开着的时候，识别引擎该是哪一档
    private var engineWhenOn: RecognitionEngineChoice {
        AISetup.engine(provider: provider, cloudRecognition: true)
    }

    /// 这一家的云端识别供应商（摆得出这个开关就一定有；理论上取不到时按阿里云算）
    private var asrProvider: CloudASRProvider { engineWhenOn.cloudProvider ?? .alibaba }

    /// 开关显示的是**意愿**。这一段只在"这一家支持云端识别"时才渲染
    ///（见 CloudSetupCore.showsCloudRecognition），所以意愿为开 = 这一刻真的在用云端。
    private var isOn: Bool { cloudRecognitionWanted }

    /// 开关 ←→ 意愿（+ 由它推出来的引擎）。哪一档由 AISetup.engine 说了算，
    /// 界面这边不自己拼 rawValue。拨开就当场测一次（见 runCheck）；拨回去只是关掉。
    private var engineBinding: Binding<Bool> {
        Binding(get: { isOn },
                set: { on in
                    cloudRecognitionWanted = on
                    let next = AISetup.engine(provider: provider, cloudRecognition: on)
                    recognitionEngine = next.rawValue
                    Log.info("Cloud recognition wanted=\(on) engine=\(next.rawValue)")
                    onEngineChange?()
                    if on {
                        runCheck()
                    } else {
                        CloudRecognitionCheckMemory.forget(asrProvider)
                        invalidateCheck()
                    }
                })
    }

    /// 这一段刚出现在屏幕上（换服务商换过来了 / 从「只用本地」切回来了 / 刚打开设置窗口）：
    /// 开关开着、而这一家这次运行里还没当面验过 → 现在验一次。
    ///
    /// 为什么非验不可（4.3.1）：换服务商不再关掉这个开关，于是云端识别会**自动**落到
    /// 一家从没验过的服务商上。「开着的开关必须意味着它真的能用」这条不因为是自动换过去的
    /// 就打折——测不通照样把开关弹回去并写明原因（turnOff 那条路）。
    /// 为什么要有那份记忆：用户在设置里就是来回点几家对比的，切走又切回来不该每次都花一秒钱。
    private func verifyIfLandedHere() {
        guard isOn, !checking, !CloudRecognitionCheckMemory.isChecked(asrProvider) else { return }
        Log.info("Cloud recognition check on arrival provider=\(asrProvider.rawValue)")
        runCheck()
    }

    var body: some View {
        Group {
            // onChange 都挂在开关上（挂在 Group 上会被逐个子视图各触发一次）。
            Toggle(tr("识别也用云端", "Also recognize speech in the cloud"), isOn: engineBinding)
                // 引擎被别处改掉（「使用方式」切回只用本地、导入设置文件）：那句「可用 ✓」
                // 不能挂在一个已经关掉的开关旁边。**失败那句留着**——它正是开关自己弹回去的原因，
                // 擦掉它等于让开关无缘无故跳回 OFF。
                .onChange(of: recognitionEngine) { _, _ in
                    if checkOK { invalidateCheck() }
                }
                // Key 验证通过：开着的话顺手把这条链路也重测一次（一个动作管到底）
                .onChange(of: keyVerifiedTick) { _, _ in
                    if isOn { runCheck() }
                }
                // 结论是一次性快照，切语言要清掉（见 CLAUDE.md「i18n 快照字符串」）
                .onChange(of: l10n.language) { _, _ in invalidateCheck() }
                // 换服务商换过来了：这一家还没验过就现在验（见 verifyIfLandedHere）
                .onChange(of: provider) { _, _ in
                    invalidateCheck()
                    verifyIfLandedHere()
                }
                .onAppear { verifyIfLandedHere() }
            // 开关旁边只留一行：开着说型号 + 代价 + 单价，关着说默认（不出这台 Mac）+ 打开后的单价。
            // 留存、先开通模型、出错回落收进段头那颗 ⓘ（SettingsCopy.cloudRecognitionInfo）。
            //
            // 型号名写的是**实时那个**，不是设置里存的 cloudAlibabaModel：这一档默认走实时
            // 接口，存着的那个只是实时用不了时接手的整段上传档。屏幕上该写"按下去会发生什么"，
            // 而不是"设置里存着什么"。单价摆在这里而不是 ⓘ 里：两家差着近八倍，
            // 那是**选择的一部分**，不该藏在一颗要点开的气泡后面。
            Caption(isOn ? CloudStreamingSession.streamModel(for: asrProvider)
                            + " · " + SettingsCopy.cloudRecognitionCost
                            + " · " + LLMCatalog.cloudASRPriceNote(provider: asrProvider)
                         : SettingsCopy.cloudRecognitionOff + " · "
                            + SettingsCopy.cloudRecognitionPriceWhenOn(
                                LLMCatalog.cloudASRPriceNote(provider: asrProvider)))
            checkRow
        }
    }

    // MARK: 开关旁边那一行结论（原来那颗「测试识别」按钮的去处）

    /// 这一行是**一次性状态快照**（正在测 / 测完的结论），不是控件说明——所以不进
    /// SettingsCopy 那张预算表，也不用 Caption（见 SettingsCopyBudgetTests 的两条纪律）。
    @ViewBuilder
    private var checkRow: some View {
        if checking || !checkResult.isEmpty {
            Text(checking ? tr("正在测云端识别…", "Checking cloud recognition…") : checkResult)
                .font(.caption)
                .foregroundColor(checking ? .secondary : (checkOK ? .green : .orange))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 动作

    /// 配置变了：上一次的结论作废，在飞的那一次也不要了。
    /// 「正在测…」的标志位一并复位——不然改了配置之后那一行永远停在"正在测"，
    /// 等一个再也不会落地的结果。
    private func invalidateCheck() {
        checkGeneration &+= 1
        checkResult = ""
        checking = false
        // 这一位也必须清：上面那条 onChange 只在"上一次是成功"时才擦结论，
        // 留着一个陈旧的 true，下一次把开关拨开时那条 onChange 会当场把刚起飞的检查作废
        //（屏幕上"正在测…"闪一下就没了，而结果永远不会落地）
        checkOK = false
    }

    /// 拨开开关（或刚验过 Key）那一刻自动跑的这一次检查：发 1 秒合成音，报往返毫秒数。
    /// 先把接入地址试出来、模型 404 时自动换 qwen3-asr-flash（见 CloudASRSetup）。
    ///
    /// **测不通就把开关拨回 OFF**：开着的开关必须意味着"它真的能用"。不拨回去的话，
    /// 用户以为配好了，而每一次听写都要先白传一整段音频、再回落本机模型。
    /// **不管成败，结论都进日志**：4.0.0 那颗按钮报 404、日志里却一行都没有，用户只能靠抄屏。
    private func runCheck() {
        guard let config = CloudASRSettings.currentConfig() else {
            // 走到这里只可能是这半秒里引擎又被改回本机档
            Log.warn("Cloud recognition check skipped: local engine")
            return
        }
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            checkOK = false
            checkResult = tr("先在上面粘一把阿里云 Key", "Paste an Alibaba Cloud key above first")
            Log.warn("Cloud recognition check skipped: no key")
            turnOff(reason: "no key")
            return
        }
        checkGeneration &+= 1
        let generation = checkGeneration
        checking = true
        checkResult = ""
        Log.info("Cloud recognition check started provider=\(config.provider.rawValue)")

        // 这几秒里用户可能已经把开关拨回去或换了 Key：那条结论对应的是**旧**配置，
        // 落在新配置下面就是一句"可用 ✓"骗人
        func settle(_ result: Result<CloudASRProbe.Outcome, CloudASRFailure>) {
            switch result {
            case .success(let outcome):
                Log.info("Cloud recognition check ok provider=\(config.provider.rawValue) "
                         + "model=\(outcome.model ?? "-") ms=\(outcome.milliseconds)")
            case .failure(let failure):
                Log.warn("Cloud recognition check failed provider=\(config.provider.rawValue) "
                         + "status=\(failure.status) code=\(failure.code ?? "-") "
                         + "copy=" + String(failure.message.prefix(200)))
            }
            guard generation == checkGeneration else { return }
            switch result {
            case .success(let outcome):
                // 同步那条路通了，再问一句**实时**这条链路通不通：两种"可用"的体验差着一个
                // 数量级（松手 0.25 秒 vs 录完再传），而用户就是在这一刻决定要不要按下这个开关。
                // 代价是再花 1 秒音频的钱（约 $0.000035），与上面那趟探针同一量级。
                guard let live = CloudASRSettings.currentConfig() else {
                    checking = false
                    checkOK = true
                    checkResult = CloudASRProbe.successText(outcome)
                    CloudRecognitionCheckMemory.markChecked(config.provider)
                    return
                }
                CloudRecognitionCheckMemory.markChecked(config.provider)
                CloudStreamingProbe.run(config: live) { streaming in
                    Log.info("Cloud recognition realtime check=\(streaming)")
                    guard generation == checkGeneration else { return }
                    checking = false
                    checkOK = true
                    checkResult = CloudASRProbe.successText(outcome, streaming: streaming)
                }
            case .failure(let failure):
                checking = false
                checkOK = false
                checkResult = failure.message
                CloudRecognitionCheckMemory.forget(config.provider)
                turnOff(reason: "check failed")
            }
        }

        guard config.provider == .alibaba else {
            CloudASRProbe.run(config: config, completion: settle)
            return
        }
        CloudASRSetup.verifyAlibaba(apiKey: config.apiKey, config: config,
                                    candidates: CloudASRSettings.currentHostCandidates(apiKey: config.apiKey)) { result in
            switch result {
            case .success(let success):
                // 记住这台主机与真正能用的那个模型。两条设置都是 @AppStorage 绑着的，
                // 界面会自己跟上。代数对不上 = 这几秒里配置被改过：那这条结论属于旧配置，
                // 连地址带模型都不许落盘。
                if generation == checkGeneration {
                    CloudASRSettings.rememberResolution(host: success.host, model: success.model)
                }
                settle(.success(success.outcome))
            case .failure(let failure):
                settle(.failure(failure))
            }
        }
    }

    /// 测不通：把开关拨回去。**只改这两条设置**（意愿 + 引擎），Key、地址、模型一个都不动。
    ///
    /// 4.3.1 起这是**唯一**允许自动关掉这个开关的情况：换服务商不再关它，但
    /// 「开着的开关必须意味着它真的能用」这一条没变——测不通就得弹回去，并把原因留在状态行上。
    private func turnOff(reason: String) {
        guard isOn else { return }
        cloudRecognitionWanted = false
        recognitionEngine = RecognitionEngineChoice.local.rawValue
        Log.warn("Cloud recognition switched back to local: \(reason)")
        onEngineChange?()
    }
}

// MARK: - 首配那一串控件（「云端 AI」页与引导第三屏同一份）

/// 使用方式 → 服务商 → Key → 模型 →（阿里云的）云端识别开关：**整个首配只有这一串**。
///
/// 为什么非得共用到这一层：4.0.1 两处各写一份，于是「识别也用云端」那个开关只长在设置页上；
/// 4.0.2 把控件逐个抽成了组件，可**顺序、标题、那一行说明、那颗 ⓘ** 仍然是各写各的——
/// 结果同一个决定在两个地方读起来像两件事。现在连同这些一起收进这一个视图，
/// 两处只剩下真正不同的那一点：设置页是"选了就生效"，引导页是"验证通过才采纳"
/// （所以 Binding 的 setter 仍由调用方写，见 providerBinding 的两份注释）。
struct CloudSetupCore<UsageNotices: View, ProviderNotices: View>: View {

    /// 摆成 Form 的分段（设置页），还是摆成一串行（引导页那一屏是 VStack）
    enum Style { case settings, onboarding }

    let style: Style
    /// 这一刻看着的那一档（可能还没被采纳为生效服务商）
    let selected: LLMProvider
    /// 这一刻**真正生效**的那一档（Settings.llmProvider）。两处都要传：
    /// 选择器旁边那枚「正在使用 ✓」靠它，阿里云那个云端识别开关也靠它——
    /// 只是预览着阿里云就把音频改成上传，会留下一个连开关都找不到的"识别停在旧档"。
    let inUse: LLMProvider
    /// 这一刻的识别引擎。**「使用方式」那一行说什么由它决定**：AISetup.mode 把"引擎是云端"
    /// 也算成「本地 + AI」，只看档位的话，开着阿里云识别的人会在这一页第一行读到"本机识别"。
    /// 由调用方传进来（两处都有自己的 @AppStorage，开关一翻这一行就跟着重画）。
    let engine: RecognitionEngineChoice
    let usageMode: Binding<AIUsageMode>
    let provider: Binding<LLMProvider>
    let offered: [LLMProvider]
    let polishModel: Binding<String>
    let commandModel: Binding<String>
    let customModelChosen: Binding<Bool>
    /// 这把 Key 用哪条链路验（开着云端识别的阿里云档直接打识别端点）
    let keyProbe: KeyVerifier.Probe
    /// 拿来探活的型号（润色型号）
    let keyProbeModel: String
    /// 模型下拉与云端识别开关露不露面。引导页要"这一档真的通了"才露——
    /// 还没连上就先摆一个花钱的选择，用户点下去也不知道点没点上
    let showsModel: Bool
    /// 选择器下面要不要那行「这一档未配置」。引导页传 false：它自己那行
    /// providerNotAdoptedYet 把同一件事说得更全，两行并排就是同一个状态说两遍
    var showsNotSetUpHint: Bool = false
    var onKeyStatus: ((KeyVerifier.Status) -> Void)? = nil
    var onEngineChange: (() -> Void)? = nil
    /// 「使用方式」下面的边界状态（存着的 Key、润色被关掉、识别停在老档……）
    @ViewBuilder var usageNotices: () -> UsageNotices
    /// 「服务商」下面的边界状态（地址被改过、这一档还没 Key……）
    @ViewBuilder var providerNotices: () -> ProviderNotices

    /// Key 验证通过的次数。**一个动作管到底**（用户 2026-09-20 拍板：一个测试，不是三个）：
    /// 验一次 Key，下面开着的云端识别跟着重测一次。计数住在这里而不是两个调用方里，
    /// 是因为设置页与引导页共用这一串控件——写两份早晚有一处漏掉。
    @State private var keyVerifiedTick = 0
    /// 「接入地址」那一栏刚被改过的次数。推给 KeyEntryView，让它拿同一把 Key 对着新地址
    /// 重验一次——**那是整页唯一的手动测试**，所以结果仍然显示在 Key 的状态行上。
    @State private var hostChangeTick = 0

    private var usingAI: Bool { usageMode.wrappedValue == .withAI }

    /// 云端识别那一段摆不摆。
    /// **看着的和生效的必须是同一家**：只是点着预览的那一档，不该有一个能把音频送上云端的开关
    /// ——按下去就成了「识别停在旧档」那条边界状态（AISetup.showsStranded…CloudNotice）。
    ///
    /// 4.2.2 起阿里云与 OpenAI 两家都摆；OpenAI 还要求**是官方接口**
    /// （把 Base URL 指向第三方网关的人没有这条路：实时地址是写死的官方域名，
    /// 音频会绕过他自己的网关，见 CloudASRSettings.openAIUsesOfficialEndpoint）。
    private var showsCloudRecognition: Bool {
        guard selected == inUse, showsModel else { return false }
        switch selected {
        case .qwen: return true
        case .openai: return CloudASRSettings.openAIUsesOfficialEndpoint
        case .deepseek, .custom, .local: return false
        }
    }

    var body: some View {
        switch style {
        case .settings: settingsSections
        case .onboarding: onboardingRows
        }
    }

    // MARK: 设置页：一段一个 ⓘ

    @ViewBuilder
    private var settingsSections: some View {
        Section {
            usagePicker
            // 这一档现在是什么，一行说完；两档各自的代价收在段头那颗 ⓘ 里
            Caption(usageCaption)
            usageNotices()
        } header: {
            SectionHeader(title: usageTitle, info: SettingsCopy.usageInfo)
        }
        // 「只用本地」时下面一个控件都不摆：那一档的全部事实就是"不联网、不花钱"，
        // 再摆一排 AI 设置只会让人以为自己还有什么没配完
        if usingAI {
            Section {
                ProviderPickerField(selection: provider, offered: offered,
                                    inUse: inUse, showsNotSetUpHint: showsNotSetUpHint)
                providerNotices()
            } header: {
                SectionHeader(title: providerTitle, info: SettingsCopy.providerInfo)
            }
            Section {
                keyField
            } header: {
                SectionHeader(title: keyTitle, info: SettingsCopy.keyInfo(cloudASRProbe: keyProbe != .llm))
            }
            // 「接入地址」只在阿里云这一档出现：只有百炼的控制台会给你一条 apiHost，
            // OpenAI / DeepSeek 的地址是固定的，摆一个永远该留空的框只会让人以为自己漏填了
            if showsHostField {
                Section {
                    hostField
                } header: {
                    SectionHeader(title: hostTitle, info: SettingsCopy.hostInfo)
                }
            }
            if showsModel {
                Section {
                    modelField
                } header: {
                    SectionHeader(title: modelTitle,
                                  info: SettingsCopy.cloudModelInfo(provider: selected))
                }
            }
            if showsCloudRecognition {
                Section {
                    CloudRecognitionFields(keyVerifiedTick: keyVerifiedTick,
                                           onEngineChange: onEngineChange,
                                           provider: selected)
                } header: {
                    SectionHeader(title: cloudRecognitionTitle, info: cloudRecognitionInfo)
                }
            }
        }
    }

    // MARK: 引导页：同样的顺序、同样的标题、同样那几颗 ⓘ，只是没有 Form 的分段

    @ViewBuilder
    private var onboardingRows: some View {
        usagePicker
        usageNotices()
        if usingAI {
            ProviderPickerField(selection: provider, offered: offered,
                                inUse: inUse, showsNotSetUpHint: showsNotSetUpHint)
            providerNotices()
            SectionHeader(title: keyTitle, info: SettingsCopy.keyInfo(cloudASRProbe: keyProbe != .llm))
            keyField
            if showsHostField {
                SectionHeader(title: hostTitle, info: SettingsCopy.hostInfo)
                hostField
            }
            if showsModel {
                SectionHeader(title: modelTitle, info: SettingsCopy.cloudModelInfo(provider: selected))
                modelField
            }
            if showsCloudRecognition {
                SectionHeader(title: cloudRecognitionTitle, info: cloudRecognitionInfo)
                CloudRecognitionFields(keyVerifiedTick: keyVerifiedTick,
                                       onEngineChange: onEngineChange,
                                       provider: selected)
            }
        }
    }

    // MARK: 控件本体（两种摆法共用这四个）

    /// 这一档现在是什么，一行说完（哪一句由 SettingsCopy.usageCaption 这个纯函数判，单测钉死）
    private var usageCaption: String {
        SettingsCopy.usageCaption(mode: usageMode.wrappedValue, engine: engine)
    }

    /// 选择器自己不再带标签：上面那一行（设置页的段名 / 引导页的标题）写的就是「使用方式」，
    /// 两处摆在一起读起来像排版坏了。无障碍那边仍然要有名字，所以补一条 accessibilityLabel。
    private var usagePicker: some View {
        Picker(tr("使用方式：", "How you use MicType:"), selection: usageMode) {
            ForEach(AIUsageMode.allCases, id: \.rawValue) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(usageTitle)
    }

    /// 只有阿里云有「接入地址」这回事（见 QwenHostField 的注释）
    private var showsHostField: Bool { selected == .qwen }

    private var hostField: some View {
        QwenHostField(onCommit: { hostChangeTick &+= 1 })
    }

    private var keyField: some View {
        KeyEntryView(provider: selected, model: keyProbeModel, probe: keyProbe,
                     hostChangeTick: hostChangeTick,
                     onStatusChange: { status in
                         // 验证通过 = 这套配置刚刚被真的确认过一次。开着云端识别的话，
                         // 下面那个开关旁的结论也该跟着重来一遍（CloudRecognitionFields 盯着这个计数）
                         if case .connected = status { keyVerifiedTick &+= 1 }
                         onKeyStatus?(status)
                     })
    }

    private var modelField: some View {
        ModelPickerField(provider: selected,
                         polishModel: polishModel,
                         commandModel: commandModel,
                         customChosen: customModelChosen)
    }

    /// 这一段那颗 ⓘ 按家给：两家的单价、留存口径、认不认词汇表都不一样
    private var cloudRecognitionInfo: String {
        SettingsCopy.cloudRecognitionInfo(
            provider: AISetup.engine(provider: selected, cloudRecognition: true).cloudProvider
                ?? .alibaba)
    }

    // 段名只写一处：引导页指路「设置 → 云端 AI → …」时，用户要在那边认得出同一个名字
    private var usageTitle: String { tr("使用方式", "How you use MicType") }
    private var providerTitle: String { tr("服务商", "Provider") }
    private var keyTitle: String { "API Key" }
    private var hostTitle: String { tr("接入地址（可选）", "API host (optional)") }
    private var modelTitle: String { tr("模型", "Model") }
    private var cloudRecognitionTitle: String { tr("云端识别（可选）", "Cloud recognition (optional)") }
}
