import SwiftUI

// MARK: - 「云端 AI」页与引导第三屏共用的控件
//
// 为什么抽成一份：4.0.1 里引导第三屏把服务商选择器、接入地址框、模型下拉各抄了一遍，
// 于是阿里云那个「识别也用云端」开关只长在设置页上——在引导里选了阿里云的人根本看不到它，
// 也就没人告诉他云端识别是可选的、要花钱的。同一个决定只写一处，两处就不会走散
// （与 QwenHostField、PrivacyCopy 同一条纪律）。

/// 服务商分段选择器。
///
/// 换档之后要做什么**不写在这里**：设置页是"选了就生效"，引导页是"看着的那一档，
/// 验证通过才采纳"——两种语义都由调用方写进 Binding 的 setter。
struct ProviderPickerField: View {
    @Binding var selection: LLMProvider
    /// 摆出来的那几档（调用方负责把"他正在用的那一档"也带上，否则选择器会是空白的）
    let offered: [LLMProvider]

    var body: some View {
        Picker(tr("服务商：", "Provider:"), selection: $selection) {
            ForEach(offered, id: \.rawValue) { provider in
                Text(provider.segmentName).tag(provider)
            }
        }
        .pickerStyle(.segmented)
    }
}

/// 「模型」下拉：一个决定同时写回润色与指令两个型号字段。
/// 要分开设在「高级」里——下拉旁边那句说明（LLMCatalog.modelMenuSummary）就是这么写的。
struct ModelPickerField: View {
    let provider: LLMProvider
    @Binding var polishModel: String
    @Binding var commandModel: String
    /// 下拉停在「自定义…」那一项上。只影响这一页怎么显示，不落盘——落盘的永远是型号名本身。
    @Binding var customChosen: Bool

    private var menu: [LLMCatalog.ModelChoice] { LLMCatalog.modelMenu(for: provider) }

    /// 下拉 ←→ 两个型号字段。读是"现在落在选单的哪一项上"，写是"把两个字段一起改掉"。
    /// 两个字段不一样（在「高级」里分开设过）时如实显示「自定义…」，绝不把用户钉回某一项。
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
                Text(tr("这一档没有内置型号：型号名在下面的「高级」里填。",
                        "This provider has no built-in models: name the model under Advanced below."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker(tr("模型：", "Model:"), selection: selection) {
                    ForEach(menu, id: \.id) { choice in
                        Text(LLMCatalog.modelLabel(choice)).tag(choice.id)
                    }
                    // 空串 = 「自定义…」：用户自己填型号名，或者他在「高级」里把润色和指令分开设过了
                    Text(tr("自定义…", "Custom…")).tag("")
                }
                if selection.wrappedValue.isEmpty {
                    TextField(tr("型号名（润色和指令都用它）", "Model name (used for both polish and commands)"),
                              text: customText)
                        .textFieldStyle(.roundedBorder)
                }
                if let summary = LLMCatalog.modelMenuSummary(provider: provider) {
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
    /// 上传 / 计费 / 留存那几句（PrivacyCopy.cloudAlibabaLines）要不要逐句摆出来。
    /// 引导页要（那是第一次做这个选择的地方）；设置页把它们收进段头那颗 ⓘ 里——
    /// 回来改设置的人已经读过一遍，不该每次都被同样五行字推着往下滚（Plan C 的文案预算）。
    var showsPrivacyLines: Bool = true
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
            Text(tr("识别模型 \(cloudAlibabaModel)（阿里云同步接口唯一可用的型号）· 音频上传 · 按秒计费",
                    "Model \(cloudAlibabaModel) (the only model on Alibaba's synchronous API) · audio is uploaded · billed per second"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isOn, showsPrivacyLines {
                // 上传、计费、留存、先开通模型、出错回落——这几句只出现在做这个选择的地方
                ForEach(PrivacyCopy.cloudAlibabaLines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if showsPrivacyLines {
                Text(tr("默认关着：录音一个字节都不出这台 Mac。机器慢、录音长、或本机模型听不好你说的语言时才值得开。",
                        "Off by default: not a byte of audio leaves this Mac. Worth turning on when this Mac is slow, the takes are long, or the on-device model handles your language poorly."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
            Text(tr("已经填了接入地址，MicType 就只用它，不再自己试。",
                    "With an API host filled in, MicType uses only that one and never probes."))
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            // 这一行**在地址还没定下来时也要有**：钥匙串里已经有 Key 的人（从 4.0.0 升上来、
            // 或导入过设置）不会再粘一次 Key，而粘 Key 是原先唯一的探测入口。
            HStack(alignment: .firstTextBaseline) {
                Text(qwenResolvedHost.isEmpty
                     ? tr("接入地址还没试出来。", "The endpoint has not been detected yet.")
                     : tr("已试通的接入地址：", "Endpoint in use: ") + qwenResolvedHost)
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
                                 "Paste an Alibaba key above first, then detect the endpoint")
            Log.warn("Qwen host probe skipped: no key")
            return
        }
        CloudASRSettings.rememberWorkspace(fromKey: key)
        // 重新探测 = 忘掉上一次那台（否则它排在第一位，"重新"就成了摆设）
        qwenResolvedHost = ""
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
                hostProbeResult = tr("已试通的接入地址：", "Endpoint in use: ") + host
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
                                 "Cloud recognition is off - there is no cloud endpoint to test")
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
