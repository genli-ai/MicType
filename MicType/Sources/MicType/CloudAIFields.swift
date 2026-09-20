import SwiftUI

// MARK: - 「云端 AI」页与引导第三屏共用的控件
//
// 为什么抽成一份：4.0.1 里引导第三屏把服务商选择器、接入地址框、模型下拉各抄了一遍，
// 于是阿里云那个「识别也用云端」开关只长在设置页上——在引导里选了阿里云的人根本看不到它，
// 也就没人告诉他云端识别是可选的、要花钱的。同一个决定只写一处，两处就不会走散
// （与 QwenHostField、PrivacyCopy 同一条纪律）。

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

/// 阿里云那一档的「识别也用云端」开关 + 说明 + 接入地址（可选）+（设置页才有的）探测与测试。
///
/// 只有阿里云有这一档：OpenAI 的转写端点 4.0.1 起不再提供，DeepSeek 没有识别接口。
/// 开关本身只写一条设置（识别引擎），判据走 AISetup.engine（纯函数，单测钉死）。
struct CloudRecognitionFields: View {
    /// 设置页给全套（探测接入地址 / 测试识别）；引导页只摆开关、说明和接入地址框——
    /// 首配的人手上还没有"上一次试通的那台"可以重新探测。
    var showsDiagnostics: Bool = true
    /// 开关动过之后调用方要做的事（引导页据此重算"AI 现在跑不跑得起来"）
    var onEngineChange: (() -> Void)? = nil

    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue
    @AppStorage(SettingsKeys.qwenAPIHost) private var qwenAPIHost = ""
    @AppStorage(SettingsKeys.qwenResolvedHost) private var qwenResolvedHost = ""
    @AppStorage(SettingsKeys.cloudAlibabaModel) private var cloudAlibabaModel = AlibabaASRModel.qwen3Flash.rawValue

    /// 「探测接入地址」那一趟的状态与结论（快照：切语言 / 改配置就清）
    @State private var hostProbing = false
    @State private var hostProbeResult = ""
    @State private var hostProbeOK = false
    /// 「测试识别」那一行结论（同样是快照）
    @State private var cloudTesting = false
    @State private var cloudTestResult = ""
    @State private var cloudTestOK = false
    /// 这一行结论属于哪一次配置。探针要跑几秒到几分钟（阿里云超时 120s），期间用户完全可以
    /// 改地址、关掉开关——回来的那条旧结论绝不能落在新配置下面。
    @State private var cloudTestGeneration = 0

    private var isOn: Bool { RecognitionEngineChoice.parse(recognitionEngine) == .cloudAlibaba }

    /// 开关 ←→ 识别引擎。哪一档由 AISetup.engine 说了算，界面这边不自己拼 rawValue。
    private var engineBinding: Binding<Bool> {
        Binding(get: { isOn },
                set: { on in
                    let next = AISetup.engine(provider: .qwen, cloudRecognition: on)
                    recognitionEngine = next.rawValue
                    Log.info("Cloud recognition engine=\(next.rawValue)")
                    onEngineChange?()
                })
    }

    var body: some View {
        Group {
            // 三个 onChange 都挂在开关上（挂在 Group 上会被逐个子视图各触发一次）：
            // 引擎可能被别处改掉（「使用方式」切回只用本地、导入设置文件），地址可能被改，
            // 语言切换会让已经生成的结论文字变成上一门语言的快照——三种情况都要作废旧结论。
            Toggle(tr("识别也用云端", "Also recognize speech in the cloud"), isOn: engineBinding)
                .onChange(of: recognitionEngine) { _, _ in invalidateCloudTest() }
                .onChange(of: qwenAPIHost) { _, _ in
                    hostProbeResult = ""
                    invalidateCloudTest()
                }
                .onChange(of: l10n.language) { _, _ in
                    hostProbeResult = ""
                    invalidateCloudTest()
                }
            // 开关旁边只留一行：开着说代价（上传 + 按秒计费），关着说默认（不出这台 Mac）。
            // 单价、留存、先开通模型、出错回落全部收进段头那颗 ⓘ（SettingsCopy.cloudRecognitionInfo）
            Caption(isOn ? cloudAlibabaModel + " · " + SettingsCopy.cloudRecognitionCost
                         : SettingsCopy.cloudRecognitionOff)

            // 接入地址：**可选**输入框，不是选择器。地址由 MicType 自己试（见 AlibabaEndpoint），
            // 这个框只留给"我就是知道地址"的人，空着才是常态。输入框 / 说明 / 格式提示与引导页共用一份。
            QwenHostField.field(host: $qwenAPIHost)

            if showsDiagnostics {
                hostRow
                if isOn { testRow }
            }
        }
    }

    // MARK: 接入地址：试通的那台 + 重新探测（只有设置页有）

    @ViewBuilder
    private var hostRow: some View {
        if !qwenAPIHost.isEmpty {
            Caption(SettingsCopy.hostFilledManually)
        } else {
            // 这一行**在地址还没定下来时也要有**：钥匙串里已经有 Key 的人（从 4.0.0 升上来、
            // 或导入过设置）不会再粘一次 Key，而粘 Key 是原先唯一的探测入口。
            HStack(alignment: .firstTextBaseline) {
                Text(qwenResolvedHost.isEmpty
                     ? SettingsCopy.hostNotDetectedYet
                     : SettingsCopy.hostInUse + qwenResolvedHost)
                    .font(.caption)
                    .foregroundColor(qwenResolvedHost.isEmpty ? .orange : .secondary)
                    .textSelection(.enabled)
                Spacer()
                Button(hostProbing ? tr("探测中…", "Detecting…")
                                   : (qwenResolvedHost.isEmpty ? tr("探测接入地址", "Detect endpoint")
                                                               : tr("重新探测", "Detect again"))) {
                    runHostProbe()
                }
                .fixedSize()
                .disabled(hostProbing)
            }
            if !hostProbeResult.isEmpty {
                Text(hostProbeResult)
                    .font(.caption)
                    .foregroundColor(hostProbeOK ? .green : .orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var testRow: some View {
        HStack {
            Button(cloudTesting ? tr("测试中…", "Testing…") : tr("测试识别", "Test recognition")) {
                runCloudTest()
            }
            .disabled(cloudTesting)
            Spacer()
        }
        if !cloudTestResult.isEmpty {
            Text(cloudTestResult)
                .font(.caption)
                .foregroundColor(cloudTestOK ? .green : .orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 动作

    /// 配置变了：上一次的结论作废，在飞的那一次也不要了。
    /// 「测试中…」的标志位一并复位——不然改了配置之后按钮永远灰着，等一个再也不会落地的结果。
    private func invalidateCloudTest() {
        cloudTestGeneration &+= 1
        cloudTestResult = ""
        cloudTesting = false
    }

    /// 探一次接入地址：拿钥匙串里那把 Key 逐台试 `GET /compatible-mode/v1/models`（不花钱、不传音频）。
    /// **成败都进日志**——用户抄着屏幕上这句话来问的时候，日志里必须找得到。
    private func runHostProbe() {
        let key = KeychainHelper.loadAPIKey(account: LLMProvider.qwen.keychainAccount) ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hostProbeOK = false
            hostProbeResult = tr("先在上面粘一把阿里云 Key，再探测接入地址",
                                 "Paste an Alibaba Cloud key above first, then detect the endpoint")
            Log.warn("Qwen host probe skipped: no key")
            return
        }
        CloudASRSettings.rememberWorkspace(fromKey: key)
        // 重新探测 = 忘掉上一次那台（否则它排在第一位，"重新"就成了摆设）
        qwenResolvedHost = ""
        Settings.shared.qwenHostVerified = false
        hostProbing = true
        hostProbeResult = ""
        invalidateCloudTest()
        Log.info("Qwen host probe started")
        AlibabaHostResolver.resolve(apiKey: key,
                                    candidates: CloudASRSettings.currentHostCandidates(apiKey: key)) { result in
            hostProbing = false
            switch result {
            case .success(let host):
                CloudASRSettings.rememberResolution(host: host, model: nil)
                hostProbeOK = true
                hostProbeResult = SettingsCopy.hostInUse + host
            case .failure(let failure):
                hostProbeOK = false
                hostProbeResult = failure.message
                Log.warn("Qwen host probe failed status=\(failure.status) code=\(failure.code ?? "-") "
                         + "copy=" + String(failure.message.prefix(200)))
            }
        }
    }

    /// 发一次 1 秒合成音，报往返毫秒数。失败时把云端的原话摆出来（它本来就带"下一步怎么办"）。
    /// 先把接入地址试出来、模型 404 时自动换 qwen3-asr-flash（见 CloudASRSetup）。
    /// **不管成败，结论都进日志**：4.0.0 这个按钮报 404、日志里却一行都没有，用户只能靠抄屏。
    private func runCloudTest() {
        guard let config = CloudASRSettings.currentConfig() else {
            cloudTestOK = false
            cloudTestResult = tr("云端识别没开，没有云端可测",
                                 "Cloud recognition is off — there is no cloud endpoint to test")
            Log.warn("Cloud test skipped: local engine")
            return
        }
        cloudTestGeneration &+= 1
        let generation = cloudTestGeneration
        cloudTesting = true
        cloudTestResult = ""
        Log.info("Cloud test started provider=\(config.provider.rawValue)")

        // 这几秒里用户可能已经关掉开关或改了地址：那条结论对应的是**旧**配置，
        // 落在新配置下面就是一句"已连通 ✓"骗人
        func settle(_ result: Result<CloudASRProbe.Outcome, CloudASRFailure>) {
            switch result {
            case .success(let outcome):
                Log.info("Cloud test ok provider=\(config.provider.rawValue) "
                         + "model=\(outcome.model ?? "-") ms=\(outcome.milliseconds)")
            case .failure(let failure):
                Log.warn("Cloud test failed provider=\(config.provider.rawValue) "
                         + "status=\(failure.status) code=\(failure.code ?? "-") "
                         + "copy=" + String(failure.message.prefix(200)))
            }
            guard generation == cloudTestGeneration else { return }
            cloudTesting = false
            switch result {
            case .success(let outcome):
                cloudTestOK = true
                cloudTestResult = CloudASRProbe.successText(outcome)
            case .failure(let failure):
                cloudTestOK = false
                cloudTestResult = failure.message
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
                if generation == cloudTestGeneration {
                    CloudASRSettings.rememberResolution(host: success.host, model: success.model)
                }
                settle(.success(success.outcome))
            case .failure(let failure):
                settle(.failure(failure))
            }
        }
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
    /// 云端识别那一段带不带「探测接入地址 / 测试识别」（首配的人手上还没有"上一次试通的那台"）
    let showsDiagnostics: Bool
    /// 选择器下面要不要那行「这一档未配置」。引导页传 false：它自己那行
    /// providerNotAdoptedYet 把同一件事说得更全，两行并排就是同一个状态说两遍
    var showsNotSetUpHint: Bool = false
    var onKeyStatus: ((KeyVerifier.Status) -> Void)? = nil
    var onEngineChange: (() -> Void)? = nil
    /// 「使用方式」下面的边界状态（存着的 Key、润色被关掉、识别停在老档……）
    @ViewBuilder var usageNotices: () -> UsageNotices
    /// 「服务商」下面的边界状态（地址被改过、这一档还没 Key……）
    @ViewBuilder var providerNotices: () -> ProviderNotices

    private var usingAI: Bool { usageMode.wrappedValue == .withAI }

    /// 阿里云那一段（云端识别开关 + 接入地址）摆不摆。
    /// **看着的和生效的都得是阿里云**：只是点着预览的那一档，不该有一个能把音频送上云端的开关
    /// ——按下去就成了「识别停在旧档」那条边界状态（AISetup.showsStrandedAlibabaCloudNotice）。
    private var showsCloudRecognition: Bool {
        selected == .qwen && inUse == .qwen && showsModel
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
                    CloudRecognitionFields(showsDiagnostics: showsDiagnostics,
                                           onEngineChange: onEngineChange)
                } header: {
                    SectionHeader(title: cloudRecognitionTitle, info: SettingsCopy.cloudRecognitionInfo)
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
            if showsModel {
                SectionHeader(title: modelTitle, info: SettingsCopy.cloudModelInfo(provider: selected))
                modelField
            }
            if showsCloudRecognition {
                SectionHeader(title: cloudRecognitionTitle, info: SettingsCopy.cloudRecognitionInfo)
                CloudRecognitionFields(showsDiagnostics: showsDiagnostics,
                                       onEngineChange: onEngineChange)
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

    private var keyField: some View {
        KeyEntryView(provider: selected, model: keyProbeModel, probe: keyProbe,
                     onStatusChange: onKeyStatus)
    }

    private var modelField: some View {
        ModelPickerField(provider: selected,
                         polishModel: polishModel,
                         commandModel: commandModel,
                         customChosen: customModelChosen)
    }

    // 段名只写一处：引导页指路「设置 → 云端 AI → …」时，用户要在那边认得出同一个名字
    private var usageTitle: String { tr("使用方式", "How you use MicType") }
    private var providerTitle: String { tr("服务商", "Provider") }
    private var keyTitle: String { "API Key" }
    private var modelTitle: String { tr("模型", "Model") }
    private var cloudRecognitionTitle: String { tr("云端识别（可选）", "Cloud recognition (optional)") }
}
