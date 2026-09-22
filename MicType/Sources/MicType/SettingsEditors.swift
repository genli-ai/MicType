import SwiftUI
import AppKit
import ServiceManagement

// MARK: - 输入

/// 「输入」页的段序。以前第一个控件是「界面语言」——一辈子点一次的东西占了最贵的位置，
/// 而每天都要看的快捷键和录音要往下滚。顺序是"用得最多的在最前"。
///
/// 为什么写成一张有序表而不是把顺序埋在 body 里：顺序本身是这次改动的产出，得能被单测钉住，
/// 否则下一次顺手在中间插一段就悄悄退回原样了。
///
/// Plan C 拿掉了「权限」这一段：缺权限是"现在用不了"，不是一条设置——它归概览顶上那条
/// 只在缺项时出现的横幅管。
///
/// 4.1.6 加进「写作偏好」（词汇表 + 自定义规则），紧跟在快捷键后面（用户 2026-09-21 拍板）：
/// 这两个框讲的都是**我的话该怎么被写出来**，既不是"这台 Mac 怎么听"（本地识别页），
/// 也不是服务商配置（云端 AI 页）。排在第二位是因为除了快捷键，这一页就数它们改得最多。
enum InputSectionOrder: Int, CaseIterable {
    case hotkey
    case writingPreferences
    /// 4.3.3 起这一页只剩三段（用户 2026-09-22：「input 里面杂七杂八的选项太多了，
    /// 大部分都默认就行！！！大幅精简」）。这一段是最后那张没有标题的卡片：
    /// 界面语言 + 开机自启——**整页只剩这两个还值得摆出来的开关**。
    case general
}

struct InputEditor: View {
    @ObservedObject private var l10n = L10n.shared
    // 4.3.3 起这一页不再摆 playSounds / restoreClipboard / autoStopSilenceSeconds /
    // livePreview / overlayPosition 这几条（用户嫌杂），keepHistory 搬去了「关于 → 隐私」。
    // **那几条设置本身照旧生效**：运行时读的是 Settings.shared.*，导入设置文件也照样能改，
    // 这里只是不再声明一份界面用的投影。
    // 写作偏好（4.1.6 起住在这一页）：词汇表从「本地识别」搬来，自定义规则从「云端 AI」搬来
    @AppStorage(SettingsKeys.customVocabulary) private var vocabulary = ""
    @AppStorage(SettingsKeys.customPolishRules) private var customRules = ""
    @AppStorage(SettingsKeys.recognitionLanguage) private var recognitionLanguage = RecognitionLanguages.autoCode
    /// 只读：自定义规则在「只用本地」这一档下一个字都不会发出去，要当面说一句
    @AppStorage(SettingsKeys.polishLevel) private var polishLevel = PolishLevel.smart.rawValue
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    /// 上一次开关登录项被系统拒了。开关自己弹回去是这一刻唯一的反馈，等于没有反馈
    @State private var launchAtLoginRefused = false

    /// 选了阿语：给一条**词汇表**提示（判据与文案都跟着词汇表一起从「本地识别」搬过来）。
    /// 2026-09-19 的实测说明为什么——同一段阿英混说的素材，默认 0.6B 无上下文 CER 12.5%，
    /// 把英文专名加进词汇表（热词）之后降到 4.0%；而 1.7B 基本不吃热词，反而是 16.8%。
    /// 所以对用户最有用的动作是填词表，不是换模型。
    private var showsArabicVocabularyTip: Bool {
        recognitionLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ar"
    }

    /// 这一刻 AI 开着没有（自定义规则只有开着 AI 才会被发出去）。判据与「云端 AI」页同一个纯函数
    private var usageMode: AIUsageMode {
        AISetup.mode(polishLevel: PolishLevel(rawValue: polishLevel) ?? .smart,
                     engine: RecognitionEngineChoice.parse(recognitionEngine))
    }

    var body: some View {
        // MeasuredFormPage：窗口高度跟着这一页的内容走（见 SettingsWindowSizing）
        MeasuredFormPage(route: .input) {
            Form {
                ForEach(InputSectionOrder.allCases, id: \.self) { section in
                    sectionView(section)
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: InputSectionOrder) -> some View {
        switch section {
        case .hotkey: hotkeySection
        case .writingPreferences: writingPreferencesSection
        case .general: generalSection
        }
    }

    // MARK: ① 快捷键

    private var hotkeySection: some View {
        Section {
            // 一行事实，不是一个控件（用户 2026-09-20 拍板：只留右 Option 这一个选择）。
            // 4.1.0 之前这里是三选一的选择器，另外两颗键除了让后面每一句操作说明
            // 都可能对不上他按的那一颗之外，没给过任何人任何好处。
            // 名字一律写全（「右 Option (⌥)」），不用 R⌥ 这种只有作者认得的缩写。
            //
            // 「重新打开引导」也从这一段搬走了：它不是一条输入设置，而是"再看一遍那份说明"
            // ——归概览底下那排小字（关于 · 隐私 · 检查更新 · 重看引导）。
            //
            // 4.3.2 删掉了段标题「快捷键 ⓘ」：它和下面那行栏名逐字相同（用户 2026-09-22
            // 嫌的就是这个），ⓘ 原样搬到这一行的右端。
            SettingsFieldRow(label: tr("快捷键", "Hotkey"), info: SettingsCopy.hotkeyInfo) {
                Text(HotkeyChoice.rightOption.displayName)
                    .foregroundColor(.secondary)
                Spacer()
            }
            // 这一行留着：轻点 / 按住是这个产品的**全部操作**，不是一句解释
            Caption(SettingsCopy.hotkeyGestures)
        }
    }


    // MARK: ② 写作偏好（词汇表 + 自定义规则）

    /// 两个框，一段。**都是"我的话该怎么被写出来"**，所以它们属于这一页而不是另外两页：
    ///   • 词汇表原来在「本地识别」页——可它对云端识别同样作为热词生效，摆在那一页
    ///     等于说"这是本机模型的事"；
    ///   • 自定义规则原来在「云端 AI」页的服务商那一段下面——于是挨个点三家看看的人
    ///     会以为每家各有一份要填（用户 2026-09-21 原话：「现在似乎每个地方都有 Customer Rules」）。
    ///
    /// 段头那颗 ⓘ 不摆：两个框各有各的细则（vocabularyInfo / customRulesInfo），
    /// 挂在各自的标题上——一颗把两件事混着讲的 ⓘ 谁也读不完。
    private var writingPreferencesSection: some View {
        Section {
            // ——— 词汇表（标题连同"逗号或换行分隔"这句格式说明一起搬过来；
            // 原来末尾那个冒号去掉了：它现在和「自定义规则」是并排的两个小标题，
            // 一个带冒号一个不带，看着就像其中一个写漏了）
            SectionHeader(title: tr("专有词汇表（逗号或换行分隔）",
                                    "Custom vocabulary (comma or newline separated)"),
                          info: SettingsCopy.vocabularyInfo)
            TextEditor(text: $vocabulary)
                .font(.system(size: 12))
                .frame(height: 76)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
            // 这条提示就摆在词汇表这一段里：它要用户做的动作正是"往上面这个框里填词"。
            // 与引擎无关——词汇表对云端同样作为热词生效。
            if showsArabicVocabularyTip {
                Caption(SettingsCopy.vocabularyArabicTip)
            } else {
                Caption(SettingsCopy.vocabularyHardReplace)
            }

            // ——— 自定义规则（4.1.1 起「关于我」也在这一个框里）
            SectionHeader(title: tr("自定义规则", "Custom rules"),
                          info: SettingsCopy.customRulesInfo)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $customRules)
                    .font(.system(size: 12))
                    .frame(height: 76)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                // 空框里的灰字：这个框最大的门槛不是不会打字，是不知道该往里写什么。
                // allowsHitTesting(false) 让点击穿过去落到编辑器上
                if customRules.isEmpty {
                    Text(SettingsCopy.customRulesPlaceholder)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            // 「只用本地」这一档下这个框一个字都不会被发出去。**框照样能填、能存**——
            // 先写规则再开 AI 是完全正常的顺序，禁用它只会让人以为坏了（判据见 AISetup）
            if AISetup.showsRulesNeedAINote(mode: usageMode) {
                Caption(SettingsCopy.rulesNeedAI)
            }
        } header: {
            SectionHeader(title: tr("写作偏好", "Writing preferences"))
        }
    }


    // MARK: ③ 通用（界面语言 + 开机自启）
    //
    // 4.3.3 把这一页砍到只剩这两个开关（用户 2026-09-22：「大部分都默认就行！！！大幅精简」）。
    // 从界面上拿掉的六样：悬浮窗位置、静音自动停止录音、录音时显示实时识别草稿、
    // 单次录音上限那一行、开始/完成提示音、输入后恢复剪贴板。
    //
    // **设置键一个都没删**（SettingsKeys / SettingsBackup 原样）：用户上次选的仍然算数
    //（2026-09-21 定的规矩：保留上次的选择，不重置），导入设置文件照样能设它们。
    // 只是它们从此走出厂默认，不再占用户每天都要扫一遍的那块地方。
    //
    // 「导入 / 导出设置」与「保存听写历史」搬去了「关于」页：前者一年用一次，
    // 后者是一条隐私开关，归隐私那一段（4.3.3）。

    private var generalSection: some View {
        Section {
            // 栏名不再双语（4.3.3）：**分段选择器里那两项本身就写着「中文」和「English」**
            //（AppLanguage.displayName），界面已经是看不懂的那一种语言时，用户照样认得出
            // 自己要点哪一格——那才是这条规矩真正要保住的东西（v4.0 调研 §4.3）。
            // 于是 CJKUIStringGuardTests 里那条唯一的按行白名单也跟着删了。
            SettingsFieldRow(label: tr("界面语言", "Language")) {
                Picker("", selection: $l10n.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Toggle(tr("登录时自动启动", "Launch at login"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        launchAtLoginRefused = false
                    } catch {
                        // 用户看得见的每一次失败都要落盘（4.0.1 立的规矩）：受管的 Mac 上
                        // 登录项可能被 MDM 挡住，4.0.2 这里只把开关弹回去，日志里一个字都没有，
                        // 他把诊断信息抄给我也查不出所以然。原因不上屏——系统给的那句话可能是
                        // 另一种语言，英文界面不能冒出中文（见 CJKUIStringGuardTests）。
                        Log.warn("Launch at login toggle failed on=\(newValue) error=\(error)")
                        launchAtLoginRefused = true
                        launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                }
            // 一行结论 + 一颗去处，绝不写成一段话
            if launchAtLoginRefused {
                BoundaryRow(text: SettingsCopy.launchAtLoginFailed) {
                    Button(tr("打开登录项设置", "Open Login Items")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            }
        }
    }

}

// MARK: - 本地识别（麦克风 / 语言 / 本机模型 / 性能）

/// 这一页只管一件事：说出来的话怎么在**这台 Mac 上**变成字。
/// 识别引擎、云端的那把 Key、接入地址全部在「云端 AI」页——
/// 那几件事都是"要不要用 AI、用哪家"的一部分，分在两页等于让用户在两处各选一次
/// （4.0.0 正是这样选出了两个对不上的值）。这里只留云端开着时要更正的那几句话。
struct RecognitionEditor: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.qwenModelRepo) private var qwenRepo = QwenModels.defaultRepo
    @AppStorage(SettingsKeys.recognitionLanguage) private var recognitionLanguage = RecognitionLanguages.autoCode
    /// 只读：云端识别的开关在「云端 AI」页。这里读它只为把几句话说对
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue
    @ObservedObject private var downloader = QwenModelDownloader.shared
    @ObservedObject private var upgrader = ModelUpgrader.shared
    /// 模型目录到货时下拉框要立刻跟上（首启动时目录还在路上）
    @ObservedObject private var catalogStore = ModelCatalogStore.shared
    @ObservedObject private var metrics = Metrics.shared
    @State private var refreshTick = 0
    @State private var updateMessage = ""
    @State private var checkingUpdate = false

    private var modelExists: Bool {
        _ = refreshTick
        // 下到一半的目录不算"已就绪"（QwenModels.isFullyDownloaded 认 .incomplete 标记）
        return QwenModels.isFullyDownloaded(repo: qwenRepo)
    }

    /// 当前选中模型的语言能力说明（来自模型目录；没写就不占一行）。
    ///
    /// 目录是**远端可更新**的：内置那两条由单测按 16 字量着，但线上发一条 60 字的说明我们拦不住，
    /// 而这一行就摆在选择器下面。所以渲染时照同一条线截断——细则本来就该在段头那颗 ⓘ 里。
    private var selectedModelLanguagesNote: String {
        let note = catalogStore.catalog.model(repo: qwenRepo)?.languagesNote.localized ?? ""
        let limit = SettingsCopy.captionLimit
        guard note.count > limit else { return note }
        return String(note.prefix(limit - 1)) + "…"
    }

    /// 选中的这一档还在目录里吗（换代下架后就不在了）
    private var selectedModelListed: Bool {
        QwenModels.all.contains { $0.repo == qwenRepo }
    }

    /// 当前选中的识别引擎。脏值一律回落本地（RecognitionEngineChoice.parse）：
    /// 一条读不懂的设置绝不能把音频送上云端。
    private var engineChoice: RecognitionEngineChoice { RecognitionEngineChoice.parse(recognitionEngine) }

    var body: some View {
        // MeasuredFormPage：窗口高度跟着这一页的内容走（见 SettingsWindowSizing）
        MeasuredFormPage(route: .recognition) {
            Form {
                // 一张没有段标题的卡片：麦克风 / 识别语言 / 识别模型（4.3.2）。
                // 原来这三段的段标题与它们下面第一行的栏名逐字相同（「麦克风 ⓘ」→「麦克风：」），
                // 那正是用户 2026-09-22 说的冗余。三颗 ⓘ 一个字没改，各自搬到自己那一行的右端。
                // 麦克风那一段与引导第二屏共用同一个组件（MicCheck.swift），引导页不摆 ⓘ。
                Section {
                    MicCheckPanel(info: SettingsCopy.micCheckInfo)
                    languageSection
                    localModelSection
                }

                // 「词汇表」4.1.6 起不在这一页（用户 2026-09-21 拍板）：它是"我的话该怎么写"，
                // 对云端识别同样作为热词生效——摆在这一页等于说"这是本机模型的事"。
                // 现在和自定义规则并成一段，住在 设置 → 输入 → 写作偏好。

                // 性能：只是照镜子，不提供任何"自动优化"开关——快慢的原因摆出来，怎么调由用户决定
                Section {
                    performanceSection
                } header: {
                    SectionHeader(title: tr("性能", "Performance"), info: SettingsCopy.performanceInfo)
                }
            }
            .formStyle(.grouped)
            .onReceive(downloader.$isDownloading) { _ in
                refreshTick += 1
            }
            .onChange(of: qwenRepo) { _, _ in
                updateMessage = ""
                QwenEngine.shared.unloadModel()
                refreshTick += 1
            }
            // 已生成的状态文字是快照，切换语言后清掉，避免残留旧语言。
            // 下载状态不在其列：它现在存的是语言中性的 phase，文字由 tr() 现场渲染，下载中也跟着切
            .onChange(of: l10n.language) { _, _ in
                updateMessage = ""
                if !upgrader.isBusy { upgrader.clearStatus() }
            }
        }
    }

    // MARK: 识别语言（本地与云端共用这一条设置）

    @ViewBuilder
    private var languageSection: some View {
        // 英文写短的 "Language"：这一页叫 On-device recognition，选单里写着
        // "Detect automatically"，不会和「界面语言」混（那一个在「输入」页，标着
        // "Language / 界面语言"）。写全的话 88pt 的栏名列装不下，会折成两行
        SettingsFieldRow(label: tr("识别语言", "Language"),
                         info: SettingsCopy.languageInfo) {
            Picker("", selection: $recognitionLanguage) {
                Text(tr("自动检测（默认）", "Detect automatically (default)"))
                    .tag(RecognitionLanguages.autoCode)
                ForEach(RecognitionLanguages.pickerOrdered) { lang in
                    Text(lang.displayName).tag(lang.code)
                }
            }
            .labelsHidden()
        }
        // 云端的语言表比这张选单短：选了它不认识的码（荷兰语、波斯语、希腊语…）时，
        // 提示根本送不出去，云端照常自动检测。那句"选了就送过去"对这几种语言是假的，
        // 必须当面换一句话——挑语言的人图的恰恰是"说小语种更稳"。
        //
        // **另一支没有了**（4.3.2）：「自动检测对中英文很准」是一句常驻的安慰话，
        // 已并进这一行的 ⓘ（languageInfo）。剩下这一条只在真的选错了语言时才出现。
        if engineChoice.isCloud,
           !CloudASRSettings.cloudHintDelivered(recognitionLanguage: recognitionLanguage) {
            Caption(SettingsCopy.cloudTakesNoHint, warning: true)
        }
    }


    // MARK: 本地模型（下载 / 升级 / 体量）

    @ViewBuilder
    private var localModelSection: some View {
        // 升级横幅：非模态、可忽略，永不自动换模型（换代要下几百 MB，这种事只由用户点）
        upgradeBanner
        SettingsFieldRow(label: tr("识别模型", "Speech model"), info: SettingsCopy.modelInfo) {
            Picker("", selection: $qwenRepo) {
                ForEach(QwenModels.all, id: \.repo) { m in
                    Text(m.sizeNote.isEmpty ? m.title : "\(m.title) · \(m.sizeNote)").tag(m.repo)
                }
                // 目录里已经不列这一档了（换代下架），但用户正在用它：如实列出来，
                // 不自动替他换（Picker 少一个能选中的选项会显示空白，那才是真的看不懂）
                if !selectedModelListed {
                    Text(SettingsCopy.modelNoLongerListed).tag(qwenRepo)
                }
            }
            .labelsHidden()
        }
        if !selectedModelLanguagesNote.isEmpty {
            Caption(selectedModelLanguagesNote)
        }
        HStack {
            Image(systemName: modelExists ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundColor(modelExists ? .green : .orange)
            Text(modelExists ? SettingsCopy.modelReady : SettingsCopy.modelNotDownloaded)
            Spacer()
            if downloader.isDownloading {
                Button(tr("取消", "Cancel")) { downloader.cancel() }
            } else {
                Button(modelExists ? tr("重新下载 / 更新", "Re-download / Update")
                                   : tr("下载模型", "Download Model")) {
                    updateMessage = ""
                    QwenEngine.shared.unloadModel()
                    downloader.download(repo: qwenRepo, force: modelExists)
                }
                // 一个按钮查两件事：模型目录里有没有更好的模型，以及当前仓库有没有新修订。
                // 结论落在下面那行文字里，横幅（如果有）负责给「一键升级」的按钮。
                Button(checkingUpdate ? tr("检查中…", "Checking…")
                                      : tr("检查模型更新", "Check for model updates")) {
                    checkingUpdate = true
                    updateMessage = ""
                    upgrader.checkNow { message in
                        checkingUpdate = false
                        updateMessage = message
                    }
                }
                .disabled(checkingUpdate || upgrader.isBusy)
            }
        }
        if downloader.isDownloading {
            ProgressView(value: downloader.progress)
        }
        if !downloader.statusText.isEmpty {
            Caption(downloader.statusText)
        }
        if !updateMessage.isEmpty {
            // 有事可做才用橙色：「已是最新」不该长得像警告
            Caption(updateMessage, warning: upgrader.decision != .none)
        }
        // 云端识别开着的时候，本机模型并没有变成多余的东西——不说清的话，用户会把它删掉，
        // 然后发现草稿没了、云端一出错就整段丢了
        if engineChoice.isCloud {
            Caption(SettingsCopy.localModelStillUsed)
        }
    }


    /// 模型升级横幅。非模态、可「以后再说」，按钮上写清这次要下多少——
    /// 一个会花掉几百 MB 流量的动作，绝不能让用户点下去才知道代价。
    @ViewBuilder
    private var upgradeBanner: some View {
        switch upgrader.decision {
        case .none:
            // 没什么可升级的时候横幅不占地方；但刚跑完（成功或失败）那句结论要留在屏幕上
            if !upgrader.statusText.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: upgrader.phase == .failed
                          ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundColor(upgrader.phase == .failed ? .orange : .green)
                    Caption(upgrader.statusText)
                }
            }
        case .upgrade(let repo):
            bannerBox(icon: "sparkles",
                      title: SettingsCopy.modelUpgradeAvailable + upgrader.displayName(for: repo)) {
                Button(upgradeButtonTitle(repo: repo)) {
                    updateMessage = ""
                    upgrader.startUpgrade()
                }
                .disabled(upgrader.isBusy || downloader.isDownloading)
                Button(tr("以后再说", "Not now")) { upgrader.dismissCurrentOffer() }
                    .disabled(upgrader.isBusy)
            }
        case .refresh:
            bannerBox(icon: "arrow.triangle.2.circlepath",
                      title: SettingsCopy.modelHasNewRevision) {
                Button(tr("重新下载并校验", "Re-download and verify")) {
                    updateMessage = ""
                    upgrader.startUpgrade()
                }
                .disabled(upgrader.isBusy || downloader.isDownloading)
                // 这一条是三种提示里最该能拒绝的：重下几百 MB 换来的是同一个模型。
                // 「以后再说」压住的是**这一份文件**，上游真出下一版时提示照样回来。
                Button(tr("以后再说", "Not now")) { upgrader.dismissCurrentOffer() }
                    .disabled(upgrader.isBusy)
            }
        case .needsAppUpdate(_, let minVersion):
            bannerBox(icon: "exclamationmark.triangle",
                      title: SettingsCopy.modelNeedsAppUpdate(version: minVersion)) {
                Button(tr("去检查 MicType 更新", "Check for MicType updates")) {
                    SettingsNavigator.shared.go(to: .about, intent: .checkUpdate)
                }
                Button(tr("以后再说", "Not now")) { upgrader.dismissCurrentOffer() }
            }
        }
    }

    /// 升级按钮的标题：把体量写在按钮上（已经下载过就不必再提体量）
    private func upgradeButtonTitle(repo: String) -> String {
        if QwenModels.isFullyDownloaded(repo: repo) {
            return tr("升级并切换", "Upgrade and switch")
        }
        let size = upgrader.sizeNote(for: repo)
        if size.isEmpty { return tr("下载并升级", "Download and upgrade") }
        return tr("下载并升级（\(size)）", "Download and upgrade (\(size))")
    }

    @ViewBuilder
    private func bannerBox<Actions: View>(icon: String, title: String,
                                          @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon).foregroundColor(.orange)
                Text(title).fontWeight(.medium)
            }
            HStack(spacing: 10) { actions() }
            if upgrader.isBusy || !upgrader.statusText.isEmpty {
                Caption(upgrader.statusText)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: 性能

    @ViewBuilder
    private var performanceSection: some View {
        if let digest = Metrics.digest(metrics.items) {
            Text(Metrics.summaryLine(digest))
                .monospacedDigit()
        } else {
            Text(tr("还没有可统计的记录——正常用几次就会出现。",
                    "No sessions recorded yet — dictate a few times and this will fill in."))
                .foregroundColor(.secondary)
        }
        if engineChoice.isCloud {
            // "识别在本机完成"对云端档不成立，得当面更正，别让用户拿本机的账去读云端的数
            Caption(SettingsCopy.performanceCloudRoundTrip)
        }
    }

}

// MARK: - 云端 AI（润色 + 语音指令 + 可选的云端识别）

/// 这一页的形状：**整页只有一个决定**开路。
/// ① 使用方式：只用本地 / 本地 + AI；② 选了 AI 再选一个服务商、贴一把 Key；
/// ③ 一个「模型」下拉（润色和指令都用它）；④ 只有阿里云多一个「识别也用云端」开关；
/// ⑤ 联网搜索（支持的服务商默认开）。**到此为止**。
/// 「高级」整段只剩没有内置清单那两档（其他兼容服务 / 本机模型）的型号名输入框与
/// 「刷新模型列表」——三家官方档连这一段都不渲染。
///
/// 4.1.6 又收掉两样（用户 2026-09-21 拍板），两样都是"摆错了地方"而不是"写长了"：
///   • **「自定义规则」**——它讲的是"我的话该怎么写"，不是服务商配置。摆在服务商那一段
///     下面的结果是：挨个点三家看看的人以为每家各有一份规则要填（用户原话：「现在似乎
///     每个地方都有 Customer Rules」）。现在它和词汇表一起住在「输入 → 写作偏好」。
///   • **「优先处理」**——OpenAI 官方接口现在一律走 Fast 档（LLMClient.asksForFastTier），
///     用户不再被问这个问题；代价（token 单价约 2 倍）在 关于 → 隐私 里说一次。
///
/// 4.1.4 又收掉三样（用户 2026-09-20 实测后拍板：「一个测试，不是三个」）：
///   • **「测试模型」**——三家官方档的型号来自下拉、Key 在上面粘的时候就验过了，
///     这颗按钮测的是同一件事；
///   • **「测试识别」**——并进"把云端识别开关拨开"那一下（CloudRecognitionFields.runCheck）；
///   • **「接入地址（可选）」**——地址改由 App 并发试一圈、挑最快的（见 AlibabaEndpoint）。
///
/// 4.1.1 按用户 2026-09-20 的实测反馈又收掉四样（每一样都是"同一件事说了两遍"）：
///   • **「关于我」**——和「自定义规则」并成一个框（谁也说不清哪句话该写在哪个框里）；
///   • **分开设润色 / 指令型号**——全部同一个型号，「高级」里那两个输入框连同各自的测试按钮一起没了；
///   • **「优先处理」在非 OpenAI 档下灰着摆着**——现在整行不渲染（灰着 + 一行"只有 OpenAI 有"，
///     是用两行讲一件与这位用户无关的事）；
///   • **换服务商点一下就生效**——现在点一下只是预览，钥匙串里有 Key 才采纳，
///     旁边那枚「正在使用 ✓」始终写着真正生效的是哪一档。
///
/// 4.0.2 又拿掉了两样东西（用户 2026-09-19 实测后拍板）：
///   • **温度滑杆**——推理系型号根本不接受自定义温度，而这是绝大多数人不该碰的旋钮。
///     设置键与内部默认值原样留着，只是界面上不再摆它。
///   • **「其他 OpenAI 兼容服务 / 本机模型」的地址与型号输入框**——那是给 Ollama、公司网关
///     准备的高级动作，用「导入设置…」配置即可。已经在用的人一切照旧。
struct CloudEditor: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.polishLevel) private var polishLevel = PolishLevel.smart.rawValue
    @AppStorage(SettingsKeys.llmProvider) private var provider = LLMProvider.openai.rawValue
    @AppStorage(SettingsKeys.openaiBaseURL) private var baseURL = "https://api.openai.com/v1"
    @AppStorage(SettingsKeys.chatModel) private var chatModel = LLMCatalog.defaultModel(for: .openai)
    @AppStorage(SettingsKeys.openaiCommandModel) private var openaiCommandModel = LLMCatalog.defaultModel(for: .openai)
    @AppStorage(SettingsKeys.deepseekBaseURL) private var dsBaseURL = LLMProvider.deepseek.defaultBaseURL
    @AppStorage(SettingsKeys.deepseekModel) private var dsModel = LLMCatalog.defaultModel(for: .deepseek)
    @AppStorage(SettingsKeys.deepseekCommandModel) private var dsCommandModel = LLMCatalog.defaultModel(for: .deepseek)
    @AppStorage(SettingsKeys.qwenAPIHost) private var qwenAPIHost = ""
    @AppStorage(SettingsKeys.qwenResolvedHost) private var qwenResolvedHost = ""
    @AppStorage(SettingsKeys.qwenModel) private var qwenModel = LLMCatalog.defaultModel(for: .qwen)
    @AppStorage(SettingsKeys.qwenCommandModel) private var qwenCommandModel = LLMCatalog.defaultModel(for: .qwen)
    @AppStorage(SettingsKeys.customBaseURL) private var customBaseURL = ""
    @AppStorage(SettingsKeys.customModel) private var customModel = ""
    @AppStorage(SettingsKeys.customCommandModel) private var customCommandModel = ""
    @AppStorage(SettingsKeys.localRuntime) private var localRuntime = LLMCatalog.LocalRuntime.ollama.rawValue
    @AppStorage(SettingsKeys.localModel) private var localModel = ""
    @AppStorage(SettingsKeys.localCommandModel) private var localCommandModel = ""
    @AppStorage(SettingsKeys.webSearchEnabled) private var webSearch = true
    /// 识别引擎：云端识别的开关就在这一页（阿里云那一档下面），「本地识别」页只读它。
    /// 同一个账号、同一把 Key、同一台主机只在这里选一次。
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue
    /// 「识别也用云端」的**意愿**（与当前服务商无关，见 AISetup.engine）
    @AppStorage(SettingsKeys.cloudRecognitionWanted) private var cloudRecognitionWanted = false
    /// 4.0.1 的默认型号迁移改掉了什么（"旧>新"）。点过「知道了」就清空。
    @AppStorage(SettingsKeys.modelMigrationNotice) private var modelMigrationNotice = ""
    @State private var testResult = ""
    /// 钥匙串不是 @AppStorage，删掉一把 Key 之后这一页不会自己重算。
    /// 这个计数器就是那一下"手动推一把"（只影响显示，不落盘）。
    @State private var keychainTick = 0
    @State private var testing = false
    /// 「刷新模型列表」从端点取回来的型号（只在内存里，切服务商就丢）
    @State private var fetchedModels: [String] = []
    @State private var refreshing = false
    @State private var refreshStatus = ""
    /// 「模型」下拉停在「自定义…」那一项上。只影响这一页怎么显示，不落盘。
    @State private var customModelChosen = false
    /// 选择器上**正在看**的那一档，不是生效的那一档（4.1.1 起两处同一条语义，见 adoptIfUsable）。
    /// 4.1.0 之前这一页直接绑 @AppStorage(llmProvider)：点一下就把生效服务商换掉了，
    /// 而"点着挨个看看"正是用户的真实行为——原来那一档可能正配着一把好 Key。
    @State private var pendingProvider = Settings.shared.llmProvider

    /// 选择器上看着的那一档
    private var selected: LLMProvider { pendingProvider }
    /// 真正生效的那一档（「正在使用 ✓」、联网搜索与优先处理都按它算）
    private var inUseProvider: LLMProvider { LLMProvider(rawValue: provider) ?? .openai }
    private var currentPolishLevel: PolishLevel { PolishLevel(rawValue: polishLevel) ?? .smart }
    private var engineChoice: RecognitionEngineChoice { RecognitionEngineChoice.parse(recognitionEngine) }
    /// 选择器上**看着**的这一档钥匙串里有没有 Key。只用来判"这一档是不是还没配"
    ///（选择器下面那行「这一档未配置」）。
    private var hasStoredKey: Bool {
        _ = keychainTick
        return KeychainHelper.loadAPIKey(account: selected.keychainAccount) != nil
    }

    private var usageMode: AIUsageMode {
        AISetup.mode(polishLevel: currentPolishLevel, engine: engineChoice)
    }

    /// 某一档这一刻的 Base URL。**从 @AppStorage 的值推**而不是读 Settings.currentBaseURL：
    /// 后者不是 @Published，改了接入地址界面不会重算。
    private func effectiveBaseURL(for provider: LLMProvider) -> String {
        switch provider {
        case .openai: return baseURL
        case .deepseek: return dsBaseURL
        case .qwen:
            // 接入地址是试出来的：粘了就用粘的，否则用试通的那台（见 AlibabaEndpoint）
            let host = AlibabaEndpoint.normalizeHost(qwenAPIHost)
                ?? AlibabaEndpoint.normalizeHost(qwenResolvedHost)
            return host.map { AlibabaEndpoint.compatibleBaseURL(host: $0) } ?? Settings.shared.qwenBaseURL
        case .custom: return customBaseURL
        case .local: return (LLMCatalog.LocalRuntime(rawValue: localRuntime) ?? .ollama).baseURL
        }
    }

    /// 联网搜索按**正在使用**的那一档算，不是选择器上预览的那一档：这个开关立刻就生效，
    /// 而生效的是生效那档的写法（LLMClient 读 Settings.llmProvider）。
    private var searchStyle: LLMCatalog.WebSearchStyle {
        LLMCatalog.searchStyle(provider: inUseProvider, baseURL: effectiveBaseURL(for: inUseProvider))
    }

    /// 润色/指令模型的输入框都绑到这两个 Binding 上——五个服务商共用一套控件
    private var polishModelBinding: Binding<String> {
        switch selected {
        case .openai: return $chatModel
        case .deepseek: return $dsModel
        case .qwen: return $qwenModel
        case .custom: return $customModel
        case .local: return $localModel
        }
    }
    private var commandModelBinding: Binding<String> {
        switch selected {
        case .openai: return $openaiCommandModel
        case .deepseek: return $dsCommandModel
        case .qwen: return $qwenCommandModel
        case .custom: return $customCommandModel
        case .local: return $localCommandModel
        }
    }

    /// 「高级」里那两个输入框右边的快选清单：内置预设在前，端点刷新来的在后
    private var modelChoices: [String] {
        LLMCatalog.mergedModelList(presets: LLMCatalog.presets(for: selected), fetched: fetchedModels)
    }

    var body: some View {
        // MeasuredFormPage：窗口高度跟着这一页的内容走（见 SettingsWindowSizing）
        MeasuredFormPage(route: .cloud) {
            Form {
                // 使用方式 → 服务商 → Key → 模型 →（阿里云的）云端识别开关：
                // 与引导第三屏**同一个视图**（CloudSetupCore），顺序、标题、说明、ⓘ 全都只写一处。
                // 4.1.1 起连语义也一样了：两处都是"看着的那一档，验证通过才采纳"，
                // 各自只剩 Binding 的 setter 不同（这里换一档要清掉本页那几条快照）。
                CloudSetupCore(style: .settings,
                               selected: selected,
                               inUse: inUseProvider,
                               engine: engineChoice,
                               usageMode: usageModeBinding,
                               provider: providerBinding,
                               offered: offeredProviders,
                               polishModel: polishModelBinding,
                               commandModel: commandModelBinding,
                               customModelChosen: $customModelChosen,
                               keyProbe: keyProbe,
                               keyProbeModel: polishModelBinding.wrappedValue,
                               showsModel: true,
                               showsNotSetUpHint: !hasStoredKey,
                               onKeyStatus: { _ in
                                   // 钥匙串不是 @AppStorage：验证通过之后这一页要自己重算，
                                   // 并且立刻把这一档采纳为生效服务商（那正是"验证通过才换过去"）
                                   keychainTick &+= 1
                                   adoptIfUsable(selected)
                               }) {
                    usageNotices
                } providerNotices: {
                    providerNotices
                } cloudExtras: {
                    // 「联网搜索」和「识别也用云端」摆进**同一张卡片**（4.3.2）：
                    // 两个开关问的是同一件事——要不要为这个多花一笔钱。分成两段、
                    // 各带一个段标题，读起来像两件互不相干的事，而那正是用户嫌冗余的地方。
                    webSearchRows
                }
                if usageMode == .withAI {
                    // 「自定义规则」4.1.6 起不在这一页（用户 2026-09-21 拍板）：它说的是
                    // **我的话该怎么写**，不是服务商配置。摆在服务商那一段下面的后果是——
                    // 挨个点 OpenAI / DeepSeek / 阿里云看看的人，会以为每家各有一份规则要填
                    //（用户原话：「现在似乎每个地方都有 Customer Rules」）。现在它和词汇表一起
                    // 住在 设置 → 输入 → 写作偏好，整个 App 里只有那一处。
                    // 「高级」整段只留给**没有内置型号清单**的那两档（其他 OpenAI 兼容服务 / 本机模型）：
                    // 4.1.4 拿掉「测试模型」之后，三家官方档的这一段里一个控件都不剩，
                    // 而一个空的折叠段只会让人以为界面坏了（用户 2026-09-20：一个测试，不是三个）。
                    if !hasModelMenu {
                        Section {
                            modelMaintenance
                        } header: {
                            SectionHeader(title: tr("高级", "Advanced"), info: SettingsCopy.advancedInfo)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            // 回到这一页时选择器要停在**正在用**的那一档上（上一次可能只是预览到一半就走了）
            .onAppear { pendingProvider = inUseProvider }
            // 测试结果与刷新结果都是快照，切换语言后清掉，避免残留旧语言
            .onChange(of: l10n.language) { _, _ in
                testResult = ""
                refreshStatus = ""
            }
        }
    }

    // MARK: 段 1「使用方式」下面的边界状态

    /// 全都是"现在这台 Mac 处在一个说不通的状态"，所以一律一行结论 + 一颗按钮，**绝不替他改**
    @ViewBuilder
    private var usageNotices: some View {
        // 4.3.3 删掉了「只用本地时钥匙串里还存着一把 Key」那条横幅与「删掉这把 Key」按钮
        //（用户 2026-09-22 原话：「on-device only 那里不需要总提示用户 remove that key，
        // 不需要这个！！！」）。它是一条**催用户去清理**的话，而不是"现在有什么坏了"——
        // 选了只用本地就不会再有润色去花钱，而按住说指令本来就是他自己按的。
        // 删 Key 仍然有唯一一条路：把 Key 输入框清空再失焦（KeyEntryView）。
        //
        // 下面留着的三条都不一样：它们说的是**状态说不通、功能会失效**，不是让人做家务。
        // 4.0.1 的默认型号迁移可能悄悄把型号换贵了。分不出就当面说，并给一颗「知道了」。
        if let notice = LLMCatalog.modelChangeNotice(modelMigrationNotice) {
            BoundaryRow(text: notice) {
                Button(tr("知道了", "Got it")) { modelMigrationNotice = "" }
            }
        }
        // 从菜单栏把润色关掉、云端识别却还开着：这一页会显示「本地 + AI」，
        // 而轻点听写其实不润色。说出来，并给一颗打开的按钮——不替他改
        if usageMode == .withAI, currentPolishLevel == .off {
            BoundaryRow(text: SettingsCopy.polishOffInMenuBar) {
                Button(tr("打开润色", "Turn polish on")) {
                    polishLevel = PolishLevel.smart.rawValue
                }
            }
        }
        // 云端识别停在 OpenAI、服务商却不是 OpenAI：与下面阿里云那一条同一件事——
        // 那个开关只在"看着的和生效的都是这一家"时渲染，于是音频一直在上传、界面上却关不掉它。
        // 绝不替他改（音频出不出这台 Mac 只由用户点），但必须当面说，并给一颗回本机的按钮。
        if AISetup.showsStrandedOpenAICloudNotice(engine: engineChoice, provider: inUseProvider) {
            BoundaryRow(text: SettingsCopy.strandedOpenAIRecognition) {
                Button(tr("改回本机识别", "Back to on-device")) {
                    recognitionEngine = RecognitionEngineChoice.local.rawValue
                    Log.info("Stranded cloudOpenAI recognition switched back to local")
                }
            }
        }
        // 云端识别停在阿里云、服务商却不是阿里云：下面那个开关只在阿里云档渲染，于是音频
        // 一直在上传、界面上却没有关掉它的控件。同样处理：当面说 + 一颗按钮，绝不替他改。
        // 判据用**生效那档**（inUseProvider），不是选择器上预览的那一档：这条横幅说的是
        // "音频这会儿还在往阿里云传、而服务商不是阿里云"，讲的全是生效链路。按 selected 判的话，
        // 阿里云用户只是点一下 OpenAI 看看，横幅就会当面说反话，还递给他一颗关掉云端识别的按钮。
        // SettingsSummary 与 AppDelegate 的同一条判据本来就按生效档算，只有这里走散过。
        if AISetup.showsStrandedAlibabaCloudNotice(engine: engineChoice, provider: inUseProvider) {
            BoundaryRow(text: SettingsCopy.strandedAlibabaRecognition) {
                Button(tr("改回本机识别", "Back to on-device")) {
                    recognitionEngine = RecognitionEngineChoice.local.rawValue
                    Log.info("Stranded cloudAlibaba recognition switched back to local")
                }
            }
        }
    }


    /// 「使用方式」这一下到底改了什么，全在 AISetup 那几个纯函数里（单测钉死）。
    /// 这里只负责把结果写进设置，并记一行日志——用户看得见的每一次状态变化都要能在日志里找到。
    private var usageModeBinding: Binding<AIUsageMode> {
        Binding(get: { usageMode },
                set: { newMode in
                    switch newMode {
                    case .localOnly:
                        let writes = AISetup.localOnlyWrites()
                        polishLevel = writes.polish.rawValue
                        // **意愿一个字都不动**（4.3.1）：这一档只是把识别拉回本机，
                        // 切回「本地 + AI」时要能原样恢复
                        recognitionEngine = writes.engine.rawValue
                    case .withAI:
                        polishLevel = AISetup.polishAfterEnablingAI(currentPolishLevel).rawValue
                        // 把存着的那个意愿重新兑现出来（它可能在「只用本地」那一档下被暂停着）
                        let restored = AISetup.engine(provider: inUseProvider,
                                                      cloudRecognition: cloudRecognitionWanted)
                        if restored != engineChoice {
                            recognitionEngine = restored.rawValue
                            Log.info("Cloud recognition restored: provider=\(inUseProvider.rawValue) "
                                     + "engine=\(restored.rawValue)")
                        }
                    }
                    Log.info("AI usage mode=\(newMode.rawValue)")
                })
    }

    // MARK: 段 2「服务商」下面的边界状态

    @ViewBuilder
    private var providerNotices: some View {
        // 官方几档的地址被老版本改过时必须看得见：看不见的自定义地址是查不出来的故障。
        // 正常情况下这里什么都不显示。
        if (selected == .openai || selected == .deepseek),
           effectiveBaseURL(for: selected) != selected.defaultBaseURL {
            BoundaryRow(text: SettingsCopy.endpointOverridden + effectiveBaseURL(for: selected)) {
                Button(tr("恢复官方地址", "Restore the official URL")) {
                    if selected == .openai { baseURL = selected.defaultBaseURL }
                    else { dsBaseURL = selected.defaultBaseURL }
                }
            }
        }

        // 还在用自定义端点 / 本机模型的人：说清界面上为什么没有那些输入框了，并给一条回官方三档
        // 的路。**绝不替他改**——那一档可能正好好用着。
        if selected == .custom || selected == .local {
            BoundaryRow(text: SettingsCopy.endpointConfiguredByImport(provider: selected.displayName)) {
                Menu(tr("改用官方三档", "Switch provider")) {
                    ForEach([LLMProvider.openai, .deepseek, .qwen], id: \.rawValue) { target in
                        Button(target.displayName) { providerBinding.wrappedValue = target }
                    }
                }
            }
        }
    }


    /// 换服务商：**只换"正在看"的那一档**，真正生效要等 adoptIfUsable 认可
    /// （4.1.1 起与引导页同一条语义，见 AISetup.adoptsProvider 的注释）。
    private var providerBinding: Binding<LLMProvider> {
        Binding(get: { selected },
                set: { next in
                    guard next != selected else { return }
                    pendingProvider = next
                    testResult = ""
                    // 上一个端点报上来的型号清单对新端点毫无意义
                    fetchedModels = []
                    refreshStatus = ""
                    customModelChosen = false
                    keychainTick &+= 1
                    Log.info("AI provider previewed=\(next.rawValue)")
                    // 钥匙串里已经有这一档的 Key（换回上一家、或早就配过）就当场生效，
                    // 不必再逼他重粘一次
                    adoptIfUsable(next)
                })
    }

    /// 只有"这一档真的能用"才把它写成生效的服务商。判据是纯函数（AISetup.adoptsProvider），
    /// 与引导第三屏同一条：点着看看的人很多，而原来那一档可能正配着一把好 Key——
    /// 把生效服务商换成一个没 Key 的，表现是他下次按住说指令直接失败，还找不到原因。
    private func adoptIfUsable(_ next: LLMProvider) {
        let hasKey = KeychainHelper.loadAPIKey(account: next.keychainAccount) != nil
        guard AISetup.adoptsProvider(current: inUseProvider, next: next,
                                     requiresKey: next.requiresAPIKey, hasKey: hasKey,
                                     polishModel: polishModelBinding.wrappedValue) else { return }
        // 云端识别跟着换过去（4.3.1 起**不再关掉它**：用户来回点几家对比是常态，
        // 而价钱就写在开关旁边）。判据是纯函数，引导页换服务商走的是同一条。
        applyCloudRecognitionMove(next)
        provider = next.rawValue
        Log.info("AI provider adopted=\(next.rawValue)")
    }

    /// 采纳新服务商之后把识别引擎调整到位。**意愿（cloudRecognitionWanted）一个字都不动**——
    /// 它记的是"我要不要云端识别"，与这一刻用哪一家无关（用户 2026-09-21 拍板）。
    /// 真正落到新一家上时那次「它能不能用」的检查由 CloudRecognitionFields 自己发起
    /// （与手动拨开开关同一条路、同一个状态行）。
    private func applyCloudRecognitionMove(_ next: LLMProvider) {
        let move = AISetup.cloudRecognitionMove(wanted: cloudRecognitionWanted,
                                                current: engineChoice, next: next,
                                                officialOpenAI: CloudASRSettings.openAIUsesOfficialEndpoint)
        if let line = AISetup.cloudRecognitionMoveLog(move, wasCloud: engineChoice.isCloud,
                                                      next: next) {
            Log.info(line)
        }
        switch move {
        case .unchanged: break
        case .moved(let engine): recognitionEngine = engine.rawValue
        case .paused: recognitionEngine = RecognitionEngineChoice.local.rawValue
        }
    }

    /// 选择器里摆哪几档：三家云服务商，外加**正在看的那一档和正在用的那一档**
    /// （否则选择器上没有一项对得上，看着像被我们悄悄改掉了）。
    ///
    /// 两档都要摆，是因为 4.1.1 起它们可以不同：正在用「本机模型」的人点一下 OpenAI 预览，
    /// 只补 selected 的话本机模型那一段当场从选择器上消失，「正在使用 ✓」跟着消失，
    /// 屏幕上再没有任何地方写着他在用哪一家，也没有一段可以点回去。
    private var offeredProviders: [LLMProvider] {
        var list: [LLMProvider] = [.openai, .deepseek, .qwen]
        for p in [selected, inUseProvider] where !list.contains(p) { list.append(p) }
        return list
    }


    /// 这把 Key 用哪条链路验。开了云端识别的阿里云档直接打识别端点——
    /// 「模型有没有在百炼控制台开通」只有真调一次识别才验得到（/models 那一趟验不出来），
    /// 而那恰恰是 4.0.0 最常见的那个 403。其余一律走润色那条链路。
    private var keyProbe: KeyVerifier.Probe {
        (selected == .qwen && engineChoice == .cloudAlibaba) ? .cloudASR(.alibaba) : .llm
    }



    // MARK: 段 5 联网搜索（支持的服务商默认开）

    /// 不支持的服务商**连开关都不摆**：一个点了没反应的灰开关加一行"这家没有"，
    /// 是用两行讲一件与这位用户无关的事。
    ///
    /// 4.3.2 起这里不再是一个 Section：它被塞进云端识别那张卡片（见 cloudExtras），
    /// 段标题连同那颗 ⓘ 一起搬到了开关自己那一行的右端。
    @ViewBuilder
    private var webSearchRows: some View {
        if let price = LLMCatalog.webSearchPriceNote(style: searchStyle) {
            SettingsToggleRow(label: tr("语音指令允许联网搜索", "Let voice commands search the web"),
                           isOn: $webSearch, info: SettingsCopy.webSearchInfo)
            // 代价写在开关旁边：价格是**代价**，不是解释，绝不搬进 ⓘ 里
            Caption(price)
        } else {
            Caption(SettingsCopy.webSearchUnsupported)
        }
    }

    // MARK: 段 7 高级（整段只剩型号维护）
    //
    // 4.1.6 这里原本是「优先处理」那一段（一个开关 + 一行单价 + 一行"上一次跑在哪一档"）。
    // 整段删掉：OpenAI 官方接口现在一律走 Fast（LLMClient.asksForFastTier），
    // 用户不再被问这个问题，代价在 关于 → 隐私 里说一次。服务商回传的 service_tier
    // 照常解析、照常进 Metrics 与诊断信息（Diagnostics 的 lastServedTier）。

    /// 这一档有没有内置型号清单。没有（其他 OpenAI 兼容服务 / 本机模型）的那两档，
    /// 型号名只有用户自己知道——「高级」里那个输入框和「刷新」都是为他们留的。
    private var hasModelMenu: Bool { !LLMCatalog.modelMenu(for: selected).isEmpty }

    // MARK: 高级 · 型号维护
    //
    // 4.1.1 这一段**不再是折叠面板**：里面只剩一行了，而折叠三角上那句标签
    // 只能把下面那颗按钮的名字再念一遍——一层壳子，两遍同样的话。
    // 4.1.4 起整段只为**没有内置清单**的那两档渲染（见上面那个 if）。

    /// 型号名输入框 + 「刷新」+「测试」，只留给**没有内置清单**的那两档
    /// （其他 OpenAI 兼容服务 / 本机模型）：型号名只有用户自己知道，填错了没有任何提示，
    /// 所以这一档需要一颗"真发一次试试"。三家官方档的型号由上面那个下拉决定，型号名不会错，
    /// 而 Key 是不是好的在上面粘 Key 那一步就验过了——再摆一颗「测试模型」就是同一件事测两遍。
    /// 填进去的名字照样一次写回润色与指令两个字段（4.1.1 起它们永远相同）。
    @ViewBuilder
    private var modelMaintenance: some View {
        ModelField(label: tr("型号名", "Model name"),
                   text: unifiedModelBinding, presets: modelChoices,
                   testing: testing, refreshing: refreshing,
                   onTest: { runModelTest(polishModelBinding.wrappedValue) },
                   onRefresh: refreshModelList)
        if !refreshStatus.isEmpty {
            Caption(refreshStatus)
        }
        if !testResult.isEmpty {
            Text(testResult)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    /// 型号名输入框绑的那个 Binding：**写下去两个字段一起改**（润色和指令永远同一个）
    private var unifiedModelBinding: Binding<String> {
        Binding(get: { polishModelBinding.wrappedValue },
                set: { newValue in
                    polishModelBinding.wrappedValue = newValue
                    commandModelBinding.wrappedValue = newValue
                })
    }

    // MARK: 动作

    /// 当前型号的连通性/速度测试。**不再顺手保存 Key**：Key 只由「服务商」段验证通过后写钥匙串。
    /// 4.1.1 起只有一个型号可测，所以这一行结论不必再点名"润色还是指令"。
    private func runModelTest(_ model: String) {
        testing = true
        testResult = ""
        // **provider 要传选择器上那一档**：4.1.1 起选择器只是预览（selected 可以不等于生效那档），
        // 而型号名取自 selected。不传的话型号发到的是**生效那档**的端点与 Key，
        // 两档拼在一起报回一句"model not found"，用户会以为是型号名坏了。
        LLMClient.testModel(model, provider: selected) { ok, message in
            testing = false
            testResult = model + tr("：", ": ") + (ok ? "✓ " : "✗ ") + message
        }
    }

    /// 问端点「你现在有哪些型号」。失败就保持内置清单不动——刷新是锦上添花，
    /// 不该因为一次拉取失败在用户脸上弹个框。
    private func refreshModelList() {
        refreshing = true
        refreshStatus = ""
        LLMClient.fetchModelIDs { ids in
            refreshing = false
            guard let ids = ids, !ids.isEmpty else {
                refreshStatus = tr("端点没有返回模型列表，下拉里仍是内置清单",
                                   "The endpoint returned no model list — the built-in picks are unchanged")
                return
            }
            fetchedModels = ids
            refreshStatus = tr("已从端点取到 \(ids.count) 个可用型号", "Pulled \(ids.count) usable models from the endpoint")
        }
    }
}

/// 模型名输入框 + 预设快选下拉（仍可手填任意兼容模型名）+ 单独的测试按钮
private struct ModelField: View {
    let label: String
    @Binding var text: String
    let presets: [String]
    var testing: Bool = false
    var refreshing: Bool = false
    var onTest: (() -> Void)? = nil
    /// 「刷新模型列表」：问端点它现在有哪些型号。写死的清单一定会过时，端点自己不会。
    var onRefresh: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
            // 自定义端点与本机模型没有内置清单，空菜单不显示（一个点不开的箭头比没有箭头更糟）
            if !presets.isEmpty {
                Menu {
                    ForEach(presets, id: \.self) { name in
                        Button(name) { text = name }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let onRefresh = onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(refreshing)
                .help(tr("刷新模型列表", "Refresh model list"))
                .fixedSize()
            }
            if let onTest = onTest {
                Button(testing ? tr("测试中…", "Testing…") : tr("测试", "Test"), action: onTest)
                    .disabled(testing)
                    .fixedSize()
            }
        }
    }
}

// MARK: - 关于（设置里唯一讲隐私与费用的地方）

/// 已下载、等着用户点「立即安装并重启」的那个包
private struct PendingUpdate {
    let version: String
    let file: URL
}

/// 版本 / 更新 / 诊断 / 作者 + PrivacyCopy 那六句。
///
/// 为什么隐私只写在这里：那六句以前在关于页、引导欢迎页、引导结束页各写一遍，措辞还都不一样，
/// 用户只能靠猜哪一句算数（v4.0 调研 §1.12）。Plan C 再收一次口——**设置窗口里只有这一页**
/// 讲隐私与费用，别的页只在做出某个具体选择时讲那个选择自己的代价。
struct AboutPanel: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var nav = SettingsNavigator.shared
    @State private var updateStatus = ""
    @State private var checkingUpdate = false
    @State private var pendingUpdate: PendingUpdate?
    @State private var installing = false
    /// 刚复制过诊断信息：按钮就地变成「已复制」两秒
    @State private var diagnosticsCopied = false
    /// 导入导出的结果文字是一次性快照，切语言时要清掉（见 CLAUDE.md「i18n 快照字符串」）
    @State private var backupStatus = ""
    /// 「保存听写历史」4.3.3 从「输入」页搬到隐私那一段：它是一条**隐私**开关
    /// （录下来的每一句话存不存在这台 Mac 上），而不是一条输入偏好
    @AppStorage(SettingsKeys.keepHistory) private var keepHistory = true

    /// 脚注的「隐私」要滚到的锚点
    private static let privacyAnchor = "privacy"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor)
                    Text("MicType")
                        .font(.title2.bold())
                    Text(tr("版本 \(UpdateChecker.currentVersion)（构建 \(Diagnostics.buildNumber)）",
                            "Version \(UpdateChecker.currentVersion) (build \(Diagnostics.buildNumber))"))
                        .foregroundColor(.secondary)
                    // 别写死服务商：润色/指令有五档，识别也多了可选的云端引擎
                    Text(tr("轻点快捷键语音输入；按住快捷键说指令——改写、回复、草拟、翻译。",
                            "Tap the hotkey to dictate; hold it to speak commands — rewrite, reply, draft, translate."))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .font(.callout)
                    updateRow
                    backupRow
                    if let pending = pendingUpdate {
                        installRow(pending)
                    }
                    if !updateStatus.isEmpty {
                        Text(updateStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    HStack(spacing: 10) {
                        Text(tr("作者：Gen", "Built by Gen"))
                        Link("genli-ai.github.io/portfolio",
                             destination: URL(string: "https://genli-ai.github.io/portfolio/")!)
                        Link("ligen.thu@gmail.com",
                             destination: URL(string: "mailto:ligen.thu@gmail.com")!)
                    }
                    .font(.caption)
                    Divider().padding(.horizontal, 60)
                    privacyBlock
                        .id(Self.privacyAnchor)
                }
                .padding(20)
                // 窗口高度跟着这一页走（关于页本来就是 ScrollView，量里面那一叠就够）
                .measuresSettingsPage(.about)
            }
            .onAppear { runIntent(proxy: proxy) }
            .onChange(of: nav.visitCount) { _, _ in runIntent(proxy: proxy) }
        }
        .onChange(of: l10n.language) { _, _ in
            // 一次性状态文字是语言快照，切语言即清空
            updateStatus = ""
            backupStatus = ""
        }
    }

    private var updateRow: some View {
        HStack(spacing: 8) {
            Button(checkingUpdate ? tr("检查中…", "Checking…") : tr("检查更新", "Check for Updates")) {
                runUpdateCheck()
            }
            .disabled(checkingUpdate)
            Button(tr("发布页", "Releases")) {
                NSWorkspace.shared.open(UpdateChecker.releasesPage)
            }
            Button(diagnosticsCopied ? tr("已复制", "Copied")
                                     : tr("复制诊断信息", "Copy diagnostics")) {
                Diagnostics.copyToPasteboard()
                diagnosticsCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    diagnosticsCopied = false
                }
            }
        }
    }

    /// 设置备份（4.3.3 从「输入」页搬来）。
    ///
    /// 为什么归这里：导出 / 导入一年用不了一次，而它原来占着「输入」页最底下一整段——
    /// 那一页是每天要扫的地方（用户 2026-09-22：「杂七杂八的选项太多了」）。
    /// 这里本来就是"关于这台 Mac 上的 MicType"：版本、更新、诊断信息，备份是同一类事。
    /// **SettingsBackup 的逻辑一行没改**，只是按钮换了个地方。
    ///
    /// 排版**跟着这一页走**：关于页从上到下每一样都是居中的，所以这是第二排居中按钮，
    /// 紧跟在「检查更新 · 发布页 · 复制诊断信息」下面，样式与那一排相同——
    /// 第一版把它做成了带栏名的左对齐一行，夹在两排居中的东西中间像贴上去的。
    /// 栏名因此也不要了：两颗按钮自己写着「导出设置…」「导入设置…」，再加一个帽子是重复。
    private var backupRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button(tr("导出设置…", "Export Settings…")) {
                    backupStatus = SettingsBackup.runExport()
                }
                Button(tr("导入设置…", "Import Settings…")) {
                    backupStatus = SettingsBackup.runImport()
                }
                InfoButton(SettingsCopy.backupInfo)
            }
            // 一次性状态快照：只在真有话说时占地方，和上面那排的 updateStatus 同一种长相
            if !backupStatus.isEmpty {
                Text(backupStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func installRow(_ pending: PendingUpdate) -> some View {
        HStack(spacing: 8) {
            Button(installing ? tr("安装中…", "Installing…")
                              : tr("立即安装并重启", "Install and Relaunch")) {
                runInstall(pending)
            }
            .disabled(installing)
            // 老流程留作兜底：验签不过、目录不可写，或者用户就是想自己拖一次
            Button(tr("在 Finder 中显示", "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([pending.file])
            }
            .disabled(installing)
        }
    }

    /// 隐私与费用：句子取自 PrivacyCopy（引导页用的是同一批），改一处两处同步
    private var privacyBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("隐私与费用", "Privacy and cost"))
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
            ForEach(PrivacyCopy.allLines, id: \.self) { line in
                Text(line)
            }
            // 存哪儿、多少条、上不上传：出处只有 HistoryStore.storageNote 一个（条数就是那个常量）。
            // 这里只补一句"去哪儿清"——「关掉」那件事 4.3.3 起就是下面那个开关本身
            Text(HistoryStore.storageNote
                 + tr("在菜单栏「最近记录」里可以清空或逐条删除。",
                      " Clear them or delete them one by one from Recent Transcripts in the menu bar."))
            // 那个开关就摆在这几句话下面（4.3.3 从「输入」页搬来）：读完"存在哪儿、留多少条"
            // 紧接着就是"要不要存"，这是它唯一该在的位置
            SettingsToggleRow(label: tr("保存听写历史（仅本机）", "Keep transcript history (on this Mac)"),
                              isOn: $keepHistory, info: SettingsCopy.behaviourInfo)
                .font(.callout)
                .foregroundColor(.primary)
            Text(tr("「复制诊断信息」只包含版本、系统、芯片、设置摘要、最近的耗时数字和今天的日志尾巴（日志里的路径和账户名已脱敏）——不含 API Key，也不含任何听写内容，可以放心贴给别人。",
                    "“Copy diagnostics” includes only the version, system, chip, a settings summary, recent timings and today's log tail (paths and your account name in it are redacted) — never your API key and never any transcribed text, so it is safe to paste to someone."))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption)
        .foregroundColor(.secondary)
    }

    /// 从脚注哪个链接进来的，进来就把那件事做掉——他点的就是那个动作，不该再找一次按钮
    private func runIntent(proxy: ScrollViewProxy) {
        switch nav.aboutIntent {
        case .none:
            break
        case .privacy:
            DispatchQueue.main.async {
                withAnimation(SettingsNavigator.reduceMotion ? nil : .easeInOut) {
                    proxy.scrollTo(Self.privacyAnchor, anchor: .top)
                }
            }
        case .checkUpdate:
            guard !checkingUpdate else { return }
            runUpdateCheck()
        }
    }

    private func runUpdateCheck() {
        checkingUpdate = true
        updateStatus = tr("正在检查 GitHub 上的最新版本…", "Checking the latest release on GitHub…")
        UpdateChecker.checkAndDownload { result in
            checkingUpdate = false
            switch result {
            case .upToDate(let v):
                pendingUpdate = nil
                updateStatus = tr("已是最新版本（\(v)）", "You're up to date (\(v))")
            case .downloaded(let v, let file):
                pendingUpdate = PendingUpdate(version: v, file: file)
                updateStatus = tr("新版本 \(v) 已下载到「下载」文件夹——点「立即安装并重启」一步完成（会校验签名后替换当前这份并自动重开），也可以自己拖进「应用程序」替换",
                                  "Version \(v) downloaded to your Downloads folder — click “Install and Relaunch” to finish in one step (the signature is verified before this copy is replaced), or replace it manually")
            case .failed(let message):
                pendingUpdate = nil
                updateStatus = tr("检查失败：\(message)。可点「发布页」手动下载",
                                  "Check failed: \(message). Use the Releases button to download manually")
            }
        }
    }

    private func runInstall(_ pending: PendingUpdate) {
        installing = true
        updateStatus = tr("正在准备安装 \(pending.version)…", "Preparing to install \(pending.version)…")
        UpdateChecker.installAndRelaunch(archive: pending.file, version: pending.version, progress: { message in
            updateStatus = message
        }, failure: { message in
            installing = false
            // 失败不动现有这份 app：把原因摆出来，指回手动替换那条路
            updateStatus = tr("安装失败：\(message)。当前版本未改动，可点「在 Finder 中显示」手动替换",
                              "Install failed: \(message). This copy was left untouched — use “Show in Finder” to replace it manually")
        })
    }
}
