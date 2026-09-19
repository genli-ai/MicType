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
enum InputSectionOrder: Int, CaseIterable {
    case hotkey
    case overlay
    case recording
    case behaviour
    case languageAndBackup
}

struct InputEditor: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.hotkey) private var hotkey = HotkeyChoice.rightOption.rawValue
    @AppStorage(SettingsKeys.playSounds) private var playSounds = true
    @AppStorage(SettingsKeys.restoreClipboard) private var restoreClipboard = true
    @AppStorage(SettingsKeys.autoStopSilenceSeconds) private var autoStopSilence = 0.0
    @AppStorage(SettingsKeys.livePreview) private var livePreview = true
    @AppStorage(SettingsKeys.overlayPosition) private var overlayPosition = OverlayPosition.bottomCenter.rawValue
    @AppStorage(SettingsKeys.keepHistory) private var keepHistory = true
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    // 导入导出的结果文字是一次性快照，切语言时要清掉（见 CLAUDE.md「i18n 快照字符串」）
    @State private var backupStatus = ""

    private var selectedHotkey: HotkeyChoice { HotkeyChoice(rawValue: hotkey) ?? .rightOption }

    /// 秒数 0 = 关；打开时给一个保守的默认 2 秒（够停顿想词，又不至于等太久）
    private var autoStopEnabled: Binding<Bool> {
        Binding(get: { autoStopSilence > 0 },
                set: { autoStopSilence = $0 ? 2 : 0 })
    }

    var body: some View {
        Form {
            ForEach(InputSectionOrder.allCases, id: \.self) { section in
                sectionView(section)
            }
        }
        .formStyle(.grouped)
        // 已生成的状态文字是快照，切换语言后清掉，避免残留旧语言
        .onChange(of: l10n.language) { _, _ in
            backupStatus = ""
        }
    }

    @ViewBuilder
    private func sectionView(_ section: InputSectionOrder) -> some View {
        switch section {
        case .hotkey: hotkeySection
        case .overlay: overlaySection
        case .recording: recordingSection
        case .behaviour: behaviourSection
        case .languageAndBackup: languageAndBackupSection
        }
    }

    // MARK: ① 快捷键

    private var hotkeySection: some View {
        Section {
            // 只摆右侧三颗（用户 2026-09-19 拍板）：Fn 要先去系统设置里让系统放手，
            // 左侧几颗天天参与 ⌘C / ⌥← ——两类都得先上一课，摆出来等于把坑一起摆出来。
            // 名字一律写全（「右 Option (⌥)」），不再用 R⌥ 这种只有作者认得的缩写。
            Picker(tr("听写快捷键：", "Dictation hotkey:"), selection: $hotkey) {
                ForEach(HotkeyChoice.offered, id: \.rawValue) { choice in
                    Text(choice.displayName).tag(choice.rawValue)
                }
                // 老设置里存着的那一颗（左侧键 / Fn）照常工作，就得照常列出来：
                // 选择器里没有一项对得上时，控件是空白的，看着像设置被我们弄丢了
                if !HotkeyChoice.offered.contains(selectedHotkey) {
                    Text(selectedHotkey.displayName).tag(selectedHotkey.rawValue)
                }
            }
            Caption(tr("轻点听写 · 按住说指令 · Esc 取消",
                       "Tap to dictate · hold to command · Esc cancels"))
            // Fn / 🌐 不在可选那三档里了，但老设置和导入的设置文件仍然能把它存进来——
            // 存着它的人**必须**先去系统设置里让系统放手，否则每次轻点都被系统抢去切输入法
            if selectedHotkey == .fn {
                BoundaryRow(text: tr("Fn / 🌐 要先在系统设置里改成「不执行任何操作」。",
                                     "Set the 🌐 key to “Do Nothing” in System Settings first.")) {
                    Button(tr("打开键盘设置", "Open Keyboard Settings")) {
                        Permissions.openKeyboardSettings()
                    }
                }
            }
            if selectedHotkey.isLeftSideModifier {
                Caption(tr("左侧键天天参与组合键，误触更多",
                           "Left-side modifiers mistrigger more in everyday shortcuts"),
                        warning: true)
            }
            HStack {
                Text(tr("上手引导：", "Welcome guide:"))
                Spacer()
                Button(tr("重新打开引导", "Show Welcome Guide")) {
                    OnboardingWindowController.shared.show()
                }
            }
        } header: {
            SectionHeader(title: tr("快捷键", "Hotkey"), info: hotkeyInfo)
        }
    }

    private var hotkeyInfo: String {
        tr("轻点开始、再轻点结束听写；按住说完松手执行语音指令。录音中按 Esc 取消，一个字都不会输入。长录音已经转出前几段时，第一次 Esc 是「收尾并输入」——停掉还没转的部分，把转好的照常插入，再按一次才彻底丢弃。",
           "Tap to start dictation and tap again to stop; hold, speak and release to run a voice command. Esc cancels while recording and nothing is inserted. Once a long take has already produced text, the first Esc means finish and insert — the untranscribed tail is dropped and the rest goes in as usual. Press it again to discard everything.")
    }

    // MARK: ② 悬浮窗

    private var overlaySection: some View {
        Section {
            Picker(tr("悬浮窗位置：", "Overlay position:"), selection: $overlayPosition) {
                ForEach(OverlayPosition.allCases, id: \.rawValue) { position in
                    Text(position.displayName).tag(position.rawValue)
                }
            }
        } header: {
            SectionHeader(title: tr("悬浮窗", "Overlay"), info: overlayInfo)
        }
    }

    private var overlayInfo: String {
        tr("多屏时悬浮窗永远出现在鼠标所在的那块屏幕，这里只决定它落在这块屏的哪个位置。录音中和处理中可以直接点胶囊右端那颗小按钮，它这一刻写着什么就是什么（「⎋ 取消」或「⎋ 收尾并输入」），和按 Esc 完全一样，而且不会把输入焦点从当前应用抢走。",
           "On multiple displays the overlay always appears on the screen holding the pointer; this only picks where it sits on that screen. While recording or processing you can click the small button at the right end of the capsule — it does exactly what it says at that moment (⎋ Cancel, or ⎋ Finish & insert), same as pressing Esc, and it never takes focus away from the app you are typing into.")
    }

    // MARK: ③ 录音

    private var recordingSection: some View {
        Section {
            Toggle(tr("静音自动停止录音", "Stop recording after silence"), isOn: autoStopEnabled)
            if autoStopSilence > 0 {
                Stepper(value: $autoStopSilence, in: 1...5, step: 1) {
                    Text(tr("静音 \(Int(autoStopSilence)) 秒后自动结束",
                            "Stop after \(Int(autoStopSilence))s of silence"))
                }
            }
            // 开着的时候那句「默认关」就成了废话：步进器已经把行为说全了
            if autoStopSilence == 0 {
                Caption(tr("默认关：什么时候说完由你决定",
                           "Off by default: you decide when you are done"))
            }
            Toggle(tr("录音时显示实时识别草稿", "Show live transcript while recording"), isOn: $livePreview)
            // 草稿是本机模型转的（云端档不会为了看草稿把每一秒都上传一遍）。只用云端、
            // 从没下过本机模型的人打开这个开关什么也不会发生——与其让他录一遍再来报 bug，
            // 不如当面说清这个开关这会儿没有用武之地。
            if !QwenEngine.shared.isModelAvailable {
                Caption(tr("没有本机模型，草稿不会出现",
                           "No on-device model, so no draft appears"),
                        warning: true)
            } else {
                Caption(tr("草稿只出现在悬浮窗里", "The draft only ever shows in the overlay"))
            }
            // 时长上限此前在界面上无处可查，用户第一次知道它存在就是被自动收尾那一刻。
            // 数字由识别链路自己给（读的是上限那个常量），界面这边一个数字都不写死。
            Caption(DictationController.recordingLimitShort)
        } header: {
            SectionHeader(title: tr("录音", "Recording"), info: recordingInfo)
        }
    }

    private var recordingInfo: String {
        tr("自动结束＝正常收尾这一段（照常识别并输入），不是丢弃。实时草稿只出现在悬浮窗里，永远不会输入到光标处；最终结果始终是识别管线自己转出来的那一版，与草稿无关。\n",
           "Auto-stop finishes the take normally (it is still transcribed and inserted) — nothing is discarded. The live draft only appears in the floating window and never reaches your cursor; the final text always comes from the recognition pipeline itself.\n")
            + DictationController.recordingLimitCopy
    }

    // MARK: ④ 行为

    private var behaviourSection: some View {
        // 英文拼写统一用美式
        Section {
            Toggle(tr("开始 / 完成时播放提示音", "Play sounds on start / finish"), isOn: $playSounds)
            Toggle(tr("输入后恢复原剪贴板内容", "Restore clipboard after inserting"), isOn: $restoreClipboard)
            Toggle(tr("保存听写历史", "Keep transcript history"), isOn: $keepHistory)
            Toggle(tr("登录时自动启动", "Launch at login"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                }
        } header: {
            SectionHeader(title: tr("行为", "Behavior"), info: behaviourInfo)
        }
    }

    private var behaviourInfo: String {
        tr("听写历史保存在本机 ~/Library/Application Support/MicType/history.json，最多 200 条，从不上传。关掉后立即停止记录；已有的记录不会自动删除，可在菜单栏「最近记录 → 清空记录」清空，或在历史记录窗口（⌘Y）里逐条删。",
           "Transcripts are kept on this Mac in ~/Library/Application Support/MicType/history.json (up to 200) and are never uploaded. Turning this off stops recording immediately; existing entries are left alone — clear them from the menu bar (Recent Transcripts → Clear History) or delete them one by one in the History window (⌘Y).")
    }

    // MARK: ⑤ 语言与备份

    private var languageAndBackupSection: some View {
        Section {
            // 故意双语（CJKUIStringGuardTests 里唯一的按行白名单）：语言选择器是切回
            // 母语的唯一入口，界面已经是看不懂的那一种语言时，它必须还认得出来
            Picker(tr("界面语言 / Language:", "Language / 界面语言:"), selection: $l10n.language) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Button(tr("导出设置…", "Export Settings…")) {
                    backupStatus = SettingsBackup.runExport()
                }
                Button(tr("导入设置…", "Import Settings…")) {
                    backupStatus = SettingsBackup.runImport()
                }
                Spacer()
            }
            if !backupStatus.isEmpty {
                Caption(backupStatus)
            }
        } header: {
            SectionHeader(title: tr("语言与备份", "Language & Backup"), info: backupInfo)
        }
    }

    /// 清单要跟着 SettingsBackup.Key.all 走。「导入可能把识别改成云端」也写在这里——
    /// 导入后那张模态摘要确实会讲，但**决定要不要信这个文件**是在点「导入设置…」之前发生的。
    private var backupInfo: String {
        tr("导出一个 JSON 文件：词汇表、关于我、自定义规则、润色档位与型号、识别引擎与识别语言、阿里云接入地址、本机识别模型、热键与界面语言。导入是合并——词表取并集，其余只覆盖文件里出现的项。\n别人给的文件可能把识别改成云端（导入后会明确提示一次）。API Key 从不导出、也从不导入：它只在钥匙串里。文件格式 Mac 与 Windows 通用。",
           "Exports one JSON file: vocabulary, about-me, custom rules, polish mode and model names, recognition engine and language, the Alibaba API host, on-device speech model, hotkey and interface language. Import merges — vocabulary lists are unioned and other settings are overwritten only where the file has them.\nA file from someone else can switch recognition to a cloud engine (the import summary says so).\nAPI keys are never exported or imported: they live in the Keychain. The format is shared with the Windows build.")
    }
}

// MARK: - 本地识别（麦克风 / 语言 / 词汇表 / 本机模型）

/// 这一页只管一件事：说出来的话怎么在**这台 Mac 上**变成字。
/// 识别引擎、云端的 Key / 接入地址 / 「测试识别」全部在「云端 AI」页——
/// 那几件事都是"要不要用 AI、用哪家"的一部分，分在两页等于让用户在两处各选一次
/// （4.0.0 正是这样选出了两个对不上的值）。这里只留云端开着时要更正的那几句话。
struct RecognitionEditor: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.qwenModelRepo) private var qwenRepo = QwenModels.defaultRepo
    @AppStorage(SettingsKeys.recognitionLanguage) private var recognitionLanguage = RecognitionLanguages.autoCode
    @AppStorage(SettingsKeys.customVocabulary) private var vocabulary = ""
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

    /// 选了阿语：给一条**词汇表**提示。2026-09-19 的实测说明为什么——同一段阿英混说的素材，
    /// 默认 0.6B 无上下文 CER 12.5%，把英文专名加进词汇表（热词）之后降到 4.0%；
    /// 而 1.7B 基本不吃热词，反而是 16.8%。所以对用户最有用的动作是填词表，不是换模型。
    private var showsArabicVocabularyTip: Bool {
        recognitionLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ar"
    }

    /// 当前选中模型的语言能力说明（来自模型目录；没写就不占一行）
    private var selectedModelLanguagesNote: String {
        catalogStore.catalog.model(repo: qwenRepo)?.languagesNote.localized ?? ""
    }

    /// 选中的这一档还在目录里吗（换代下架后就不在了）
    private var selectedModelListed: Bool {
        QwenModels.all.contains { $0.repo == qwenRepo }
    }

    /// 当前选中的识别引擎。脏值一律回落本地（RecognitionEngineChoice.parse）：
    /// 一条读不懂的设置绝不能把音频送上云端。
    private var engineChoice: RecognitionEngineChoice { RecognitionEngineChoice.parse(recognitionEngine) }

    var body: some View {
        Form {
            // 麦克风选择 + 电平自检：与引导第二屏共用同一个组件（MicCheck.swift）
            Section {
                MicCheckPanel(showsFootnote: false)
            } header: {
                SectionHeader(title: tr("麦克风", "Microphone"), info: MicCheckPanel.footnote)
            }

            Section {
                languageSection
            } header: {
                SectionHeader(title: tr("识别语言", "Recognition language"), info: languageInfo)
            }

            Section {
                localModelSection
            } header: {
                SectionHeader(title: tr("识别模型", "Speech model"), info: modelInfo)
            }

            Section {
                vocabularySection
            } header: {
                SectionHeader(title: tr("词汇表", "Vocabulary"), info: vocabularyInfo)
            }

            // 性能：只是照镜子，不提供任何"自动优化"开关——快慢的原因摆出来，怎么调由用户决定
            Section {
                performanceSection
            } header: {
                SectionHeader(title: tr("性能", "Performance"), info: performanceInfo)
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

    // MARK: 识别语言（本地与云端共用这一条设置）

    @ViewBuilder
    private var languageSection: some View {
        Picker(tr("识别语言：", "Recognition language:"), selection: $recognitionLanguage) {
            Text(tr("自动检测（默认）", "Detect automatically (default)"))
                .tag(RecognitionLanguages.autoCode)
            ForEach(RecognitionLanguages.pickerOrdered) { lang in
                Text(lang.displayName).tag(lang.code)
            }
        }
        // 云端的语言表比这张选单短：选了它不认识的码（荷兰语、波斯语、希腊语…）时，
        // 提示根本送不出去，云端照常自动检测。那句"选了就送过去"对这几种语言是假的，
        // 必须当面换一句话——挑语言的人图的恰恰是"说小语种更稳"。
        if engineChoice.isCloud,
           !CloudASRSettings.cloudHintDelivered(recognitionLanguage: recognitionLanguage) {
            Caption(tr("云端不收这个语言的提示",
                       "The cloud engine takes no hint for this language"),
                    warning: true)
        } else {
            Caption(tr("自动检测对中英文很准，一般不用动",
                       "Automatic detection is reliable for Chinese and English"))
        }
    }

    private var languageInfo: String {
        tr("说小语种（或中英夹杂被判错）时指定语言更稳；指定只影响识别，不改任何别的行为。云端引擎读的是同一条设置：选了具体语言就作为语言提示送过去，「自动检测」交给云端自己判；云端不认识的语言码一个提示都不会送出去。",
           "Pick a language when you speak something else, or when mixed speech gets detected wrong. It only affects recognition. Cloud engines read the same setting: a specific language is sent as a hint and Detect automatically leaves the decision to the provider. A language the provider does not know is never sent as a hint at all.")
    }

    // MARK: 本地模型（下载 / 升级 / 体量）

    @ViewBuilder
    private var localModelSection: some View {
        // 升级横幅：非模态、可忽略，永不自动换模型（换代要下几百 MB，这种事只由用户点）
        upgradeBanner
        Picker(tr("识别模型：", "Speech model:"), selection: $qwenRepo) {
            ForEach(QwenModels.all, id: \.repo) { m in
                Text(m.sizeNote.isEmpty ? m.title : "\(m.title) · \(m.sizeNote)").tag(m.repo)
            }
            // 目录里已经不列这一档了（换代下架），但用户正在用它：如实列出来，
            // 不自动替他换（Picker 少一个能选中的选项会显示空白，那才是真的看不懂）
            if !selectedModelListed {
                Text(tr("当前模型（目录里已不再列出）", "Current model (no longer listed)"))
                    .tag(qwenRepo)
            }
        }
        if !selectedModelLanguagesNote.isEmpty {
            Caption(selectedModelLanguagesNote)
        }
        HStack {
            Image(systemName: modelExists ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundColor(modelExists ? .green : .orange)
            Text(modelExists ? tr("模型已就绪", "Model ready")
                             : tr("模型未下载", "Model not downloaded"))
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
            Caption(tr("本机模型仍用于草稿与回落",
                       "The on-device model still does drafts and fallback"))
        }
    }

    private var modelInfo: String {
        tr("Qwen3-ASR（2026）：约 30 种语言 + 22 种中文方言，自动检测语言，识别完全在本机进行。模型来自 HuggingFace（hf-mirror 加速）。\n云端识别开着时日常听写走云端，本机模型仍然有用——录音时那行实时草稿由它转，云端出错时也由它把这一段接住。",
           "Qwen3-ASR (2026): ~30 languages plus 22 Chinese dialects, automatic language detection, fully on-device. Models come from HuggingFace.\nWith cloud recognition on, everyday dictation goes to the cloud, but the on-device model still matters: it produces the live draft while you record, and it catches the take if the cloud call fails.")
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
                      title: tr("有更合适的识别模型：", "A better speech model is available: ")
                          + upgrader.displayName(for: repo),
                      detail: upgrader.languagesNote(for: repo)) {
                Button(upgradeButtonTitle(repo: repo)) {
                    updateMessage = ""
                    upgrader.startUpgrade()
                }
                .disabled(upgrader.isBusy || downloader.isDownloading)
                Button(tr("以后再说", "Not now")) { upgrader.dismissCurrentOffer() }
                    .disabled(upgrader.isBusy)
            }
        case .refresh(let repo):
            bannerBox(icon: "arrow.triangle.2.circlepath",
                      title: tr("当前识别模型有新修订", "The current speech model has a newer revision"),
                      detail: tr("重新下载后会校验一遍再启用；失败则保留现在这份。\(upgrader.sizeNote(for: repo))",
                                 "The re-download is verified before it is used; if it fails, the current copy is kept. \(upgrader.sizeNote(for: repo))")) {
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
        case .needsAppUpdate(let repo, let minVersion):
            bannerBox(icon: "exclamationmark.triangle",
                      title: tr("需要更新 MicType", "MicType needs an update"),
                      detail: tr("新模型「\(upgrader.displayName(for: repo))」要求 MicType \(minVersion) 或更高版本，当前是 \(UpdateChecker.currentVersion)。",
                                 "The new model “\(upgrader.displayName(for: repo))” needs MicType \(minVersion) or newer; this copy is \(UpdateChecker.currentVersion).")) {
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
    private func bannerBox<Actions: View>(icon: String, title: String, detail: String,
                                          @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon).foregroundColor(.orange)
                Text(title).fontWeight(.medium)
            }
            if !detail.isEmpty {
                Caption(detail)
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

    // MARK: 词汇表（与引擎无关，两档都生效）

    @ViewBuilder
    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("专有词汇表（人名、品牌、术语，逗号或换行分隔）：",
                    "Custom vocabulary (names, brands, jargon — comma or newline separated):"))
            TextEditor(text: $vocabulary)
                .font(.system(size: 12))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
            // 这条提示就摆在词汇表这一段里：它要用户做的动作正是"往上面这个框里填词"。
            // 与引擎无关——词汇表对云端同样作为热词生效。
            if showsArabicVocabularyTip {
                Caption(tr("阿语：把英文专名填进来最有效",
                           "Arabic: adding English product names here helps most"))
            } else {
                Caption(tr("也支持「错写=正写」的硬替换",
                           "Supports hard replacement, written as wrong=right"))
            }
        }
    }

    private var vocabularyInfo: String {
        tr("这些词作为热词直接送进识别模型，并参与 AI 润色纠错——专有名词准确率的第一杠杆。\n硬替换：「杰文=捷文」表示识别出的「杰文」一律改成「捷文」，零耗时；一个正写可挂多个错写：「杰文|捷纹=捷文」。西文词条大小写不敏感、按整词匹配。\n云端引擎吃同一张表（按权重 4 送过去）。口水词内置，不用自己列。",
           "These terms are fed to the speech model as hotwords and used by AI polish — the number one lever for proper-noun accuracy.\nHard replacement: an entry like \"Jevin=Jaywen\" rewrites every occurrence at zero latency, and one correct form can take several wrong spellings: \"Jevin|Javin=Jaywen\". Latin entries match whole words, case-insensitively.\nCloud engines use the same list (sent with weight 4). Filler words are built in — there is no list to fill in.")
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
            Caption(tr("云端档：「识别」量的是往返",
                       "Cloud engine: that figure is a round trip"))
        }
    }

    private var performanceInfo: String {
        tr("识别与插入都在本机完成；「模型」那一段是到大模型接口的网络往返（轻点是润色，按住是指令），和这台 Mac 快慢无关，后面括号里是它实际统计了几轮。\n只统计数字，不保存任何听写内容。",
           "Recognition and insertion run on this Mac; the “Model” figure is the network round trip to your model endpoint (polish when you tap, the command model when you hold) — not bound by this machine. The number in brackets is how many rounds actually went through it.\nOnly timings are stored — never any transcribed text.")
    }
}

// MARK: - 云端 AI（润色 + 语音指令 + 可选的云端识别）

/// 这一页的形状：**整页只有一个决定**开路。
/// ① 使用方式：只用本地 / 本地 + AI；② 选了 AI 再选一个服务商、贴一把 Key；
/// ③ 一个「模型」下拉（默认就是这家最好的那个）；④ 只有阿里云多一个「识别也用云端」开关；
/// ⑤ 关于我 / 自定义规则；剩下的（分开设型号、联网搜索、优先处理）收在「高级」里。
///
/// 4.0.2 又拿掉了两样东西（用户 2026-09-19 实测后拍板）：
///   • **温度滑杆**——推理系型号根本不接受自定义温度，而这是绝大多数人不该碰的旋钮。
///     设置键与内部默认值原样留着，只是界面上不再摆它。
///   • **「其他 OpenAI 兼容服务 / 本机模型」的地址与型号输入框**——那是给 Ollama、公司网关
///     准备的高级动作，用「导入设置…」配置即可。已经在用的人一切照旧。
struct CloudEditor: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var metrics = Metrics.shared
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
    @AppStorage(SettingsKeys.fastTier) private var fastTier = false
    @AppStorage(SettingsKeys.webSearchEnabled) private var webSearch = false
    @AppStorage(SettingsKeys.aboutMe) private var aboutMe = ""
    @AppStorage(SettingsKeys.customPolishRules) private var customRules = ""
    /// 识别引擎：云端识别的开关就在这一页（阿里云那一档下面），「本地识别」页只读它。
    /// 同一个账号、同一把 Key、同一台主机只在这里选一次。
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue
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
    /// 高级区默认折叠：分开设型号、联网搜索、优先处理都是少数人才动的东西，不该占首屏
    @State private var advancedExpanded = false
    /// 「模型」下拉停在「自定义…」那一项上。只影响这一页怎么显示，不落盘。
    @State private var customModelChosen = false

    private var selected: LLMProvider { LLMProvider(rawValue: provider) ?? .openai }
    private var currentPolishLevel: PolishLevel { PolishLevel(rawValue: polishLevel) ?? .smart }
    private var engineChoice: RecognitionEngineChoice { RecognitionEngineChoice.parse(recognitionEngine) }
    /// 当前这一档的钥匙串里有没有一把 Key。判的是"按住说指令会不会真的发出去"
    private var hasStoredKey: Bool {
        _ = keychainTick
        return KeychainHelper.loadAPIKey(account: selected.keychainAccount) != nil
    }
    private var usageMode: AIUsageMode {
        AISetup.mode(polishLevel: currentPolishLevel, engine: engineChoice)
    }

    /// 界面上这一刻生效的 Base URL。**从 @AppStorage 的值推**而不是读 Settings.currentBaseURL：
    /// 后者不是 @Published，改了接入地址界面不会重算。
    private var effectiveBaseURL: String {
        switch selected {
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

    private var searchStyle: LLMCatalog.WebSearchStyle {
        LLMCatalog.searchStyle(provider: selected, baseURL: effectiveBaseURL)
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
        Form {
            Section {
                usageSection
            } header: {
                SectionHeader(title: tr("使用方式", "How you use MicType"), info: usageInfo)
            }
            // 「只用本地」时下面一个控件都不摆：那一档的全部事实就是"不联网、不花钱"，
            // 再摆一排 AI 设置只会让人以为自己还有什么没配完
            if usageMode == .withAI {
                Section {
                    providerSection
                } header: {
                    SectionHeader(title: tr("服务商", "Provider"), info: providerInfo)
                }
                Section {
                    keySection
                } header: {
                    SectionHeader(title: "API Key", info: keyInfo)
                }
                Section {
                    ModelPickerField(provider: selected,
                                     polishModel: polishModelBinding,
                                     commandModel: commandModelBinding,
                                     customChosen: $customModelChosen)
                } header: {
                    SectionHeader(title: tr("模型", "Model"))
                }
                if selected == .qwen {
                    // 开关 + 说明 + 接入地址 + 「测试识别」：与引导第三屏共用同一个组件。
                    // 上传 / 计费 / 留存那几句收进 ⓘ（引导页仍然逐句摆出来——那里是第一次
                    // 做这个选择的地方，而这里的人是回来改设置的）
                    Section {
                        CloudRecognitionFields(showsPrivacyLines: false)
                    } header: {
                        SectionHeader(title: tr("云端识别（可选）", "Cloud recognition (optional)"),
                                      info: cloudRecognitionInfo)
                    }
                }
                Section {
                    personalFields
                } header: {
                    SectionHeader(title: tr("关于我与自定义规则", "About me and rules"), info: personalInfo)
                }
                Section {
                    advancedSection
                } header: {
                    SectionHeader(title: tr("高级", "Advanced"), info: advancedInfo)
                }
            }
        }
        .formStyle(.grouped)
        // 测试结果与刷新结果都是快照，切换语言后清掉，避免残留旧语言
        .onChange(of: l10n.language) { _, _ in
            testResult = ""
            refreshStatus = ""
        }
    }

    // MARK: 段 1 使用方式（整页唯一的决定）

    @ViewBuilder
    private var usageSection: some View {
        Picker(tr("使用方式：", "How you use MicType:"), selection: usageModeBinding) {
            ForEach(AIUsageMode.allCases, id: \.rawValue) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        Caption(usageMode == .localOnly
                ? tr("不联网、不花钱、不用填 Key", "No network, no cost, no key to fill in")
                : tr("本机识别，再交服务商润色",
                     "Recognized on this Mac, then polished by your provider"))
        // 「只用本地」只写回"润色关掉 + 识别回本机"两条，**钥匙串里那把 Key 不动**
        // （删 Key 是破坏性动作，只能由用户自己点）。可指令路径不看档位：按住说指令照样
        // 会把选区和这句话发给服务商、照样计费——不说的话他既看不到那把 Key，也不知道它还在花钱。
        if usageMode == .localOnly,
           AISetup.showsStoredKeyNotice(mode: usageMode, hasCredential: hasStoredKey) {
            BoundaryRow(text: tr("钥匙串里还存着 \(selected.segmentName) 的 Key，按住说指令仍会计费。",
                                 "A \(selected.segmentName) key is still in your Keychain; hold-to-command keeps billing you.")) {
                Button(tr("删掉这把 Key", "Remove that key")) {
                    KeychainHelper.deleteAPIKey(account: selected.keychainAccount)
                    Log.info("API key removed provider=\(selected.rawValue) reason=local only")
                    // 删完这一页要立刻不再显示上面那句：@AppStorage 管不着钥匙串，自己推一下
                    keychainTick &+= 1
                }
            }
        }
        // 4.0.1 的默认型号迁移可能悄悄把型号换贵了。分不出就当面说，并给一颗「知道了」。
        if let notice = LLMCatalog.modelChangeNotice(modelMigrationNotice) {
            BoundaryRow(text: notice) {
                Button(tr("知道了", "Got it")) { modelMigrationNotice = "" }
            }
        }
        // 从菜单栏把润色关掉、云端识别却还开着：这一页会显示「本地 + AI」，
        // 而轻点听写其实不润色。说出来，并给一颗打开的按钮——不替他改
        if usageMode == .withAI, currentPolishLevel == .off {
            BoundaryRow(text: tr("润色在菜单栏里关着，轻点听写只出识别原文。",
                                 "Polish is switched off in the menu bar, so tapping gives the raw transcript.")) {
                Button(tr("打开润色", "Turn polish on")) {
                    polishLevel = PolishLevel.smart.rawValue
                }
            }
        }
        // 4.0.0 的「云端 · OpenAI」识别：界面上已经没有这一档了，但设置里可能还存着。
        // 绝不替他改（音频出不出这台 Mac 只由用户点），但必须当面说，并给一颗回本机的按钮。
        if AISetup.showsLegacyOpenAICloudNotice(engine: engineChoice) {
            BoundaryRow(text: tr("这台 Mac 还在用 OpenAI 云端识别，每段录音都会上传。",
                                 "This Mac still uses OpenAI cloud recognition, so every take is uploaded.")) {
                Button(tr("改回本机识别", "Back to on-device")) {
                    recognitionEngine = RecognitionEngineChoice.local.rawValue
                    Log.info("Legacy cloudOpenAI recognition switched back to local")
                }
            }
        }
        // 云端识别停在阿里云、服务商却不是阿里云：下面那个开关只在阿里云档渲染，于是音频
        // 一直在上传、界面上却没有关掉它的控件。同样处理：当面说 + 一颗按钮，绝不替他改。
        if AISetup.showsStrandedAlibabaCloudNotice(engine: engineChoice, provider: selected) {
            BoundaryRow(text: tr("识别还走着阿里云（按秒计费），但服务商已经不是阿里云了。",
                                 "Recognition still goes to Alibaba (billed per second) although your provider is not Alibaba.")) {
                Button(tr("改回本机识别", "Back to on-device")) {
                    recognitionEngine = RecognitionEngineChoice.local.rawValue
                    Log.info("Stranded cloudAlibaba recognition switched back to local")
                }
            }
        }
    }

    private var usageInfo: String {
        tr("「只用本地」：识别和输入全在这台 Mac 上，不联网、不花钱，也不需要填 Key；按住快捷键说指令需要 AI，那一档没有。\n「本地 + AI」：轻点听写照旧在本机识别，识别完的文字交给你选的服务商润色，按住说指令也走这家。费用由服务商直接结给你，MicType 不经手、不加价。",
           "Local only: recognition and typing all happen on this Mac — no network, no cost, no key. Hold-to-command needs AI, so it is not available there.\nLocal + AI: tapping still recognizes on this Mac and the text is then polished by the provider you pick; hold-to-command uses the same one. You pay that provider directly and MicType never takes a cut.")
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
                        recognitionEngine = writes.engine.rawValue
                    case .withAI:
                        polishLevel = AISetup.polishAfterEnablingAI(currentPolishLevel).rawValue
                    }
                    Log.info("AI usage mode=\(newMode.rawValue)")
                })
    }

    // MARK: 段 2 服务商（选择器与引导第三屏共用同一个组件）

    @ViewBuilder
    private var providerSection: some View {
        ProviderPickerField(selection: providerBinding, offered: offeredProviders)

        // 官方几档的地址被老版本改过时必须看得见：看不见的自定义地址是查不出来的故障。
        // 正常情况下这里什么都不显示。
        if (selected == .openai || selected == .deepseek), effectiveBaseURL != selected.defaultBaseURL {
            BoundaryRow(text: tr("这一档的接口地址被改过：", "This provider's endpoint was overridden: ")
                        + effectiveBaseURL) {
                Button(tr("恢复官方地址", "Restore the official URL")) {
                    if selected == .openai { baseURL = selected.defaultBaseURL }
                    else { dsBaseURL = selected.defaultBaseURL }
                }
            }
        }

        // 还在用自定义端点 / 本机模型的人：说清界面上为什么没有那些输入框了，并给一条回官方三档
        // 的路。**绝不替他改**——那一档可能正好好用着。
        if selected == .custom || selected == .local {
            BoundaryRow(text: tr("「\(selected.displayName)」的接口地址改由「导入设置…」配置，现有配置照常工作。",
                                 "The endpoint for \(selected.displayName) is now configured through Import Settings; your current setup keeps working.")) {
                Menu(tr("改用官方三档", "Switch provider")) {
                    ForEach([LLMProvider.openai, .deepseek, .qwen], id: \.rawValue) { target in
                        Button(target.displayName) { providerBinding.wrappedValue = target }
                    }
                }
            }
        }
    }

    private var providerInfo: String {
        tr("三家官方档位的接口地址都是内置的，换一家只要贴那一家的 Key——每档各有一条钥匙串条目，互不覆盖，换回来不用重贴。\n「其他 OpenAI 兼容服务」与「本机模型」4.0.2 起没有入口了（那是给 Ollama、公司网关这类用户的高级动作，改由「导入设置…」配置），但正在用的人一切照旧，型号名仍然在「高级」里改。",
           "The endpoints of the three official providers are built in, so switching means pasting that provider's key. Each has its own Keychain entry, so they never overwrite each other and switching back needs no re-paste.\nOther OpenAI-compatible services and on-device models no longer have an entry point here — that is an advanced setup for Ollama or a company gateway, configured through Import Settings — but an existing setup keeps working and its model name is still editable under Advanced.")
    }

    /// 换服务商要做的事全在这个 setter 里（引导页那一处语义不同：看着的那一档要验证通过才采纳）
    private var providerBinding: Binding<LLMProvider> {
        Binding(get: { selected },
                set: { next in
                    guard next != selected else { return }
                    // 换走之后音频不能还在往阿里云传——而且界面上已经没有那个开关可以关了。
                    // 判据是纯函数，引导页换服务商走的是同一条
                    if let engine = AISetup.engineAfterProviderChange(current: engineChoice, next: next) {
                        recognitionEngine = engine.rawValue
                        Log.info("Cloud recognition off: provider=\(next.rawValue)")
                    }
                    provider = next.rawValue
                    testResult = ""
                    // 上一个端点报上来的型号清单对新端点毫无意义
                    fetchedModels = []
                    refreshStatus = ""
                    customModelChosen = false
                    Log.info("AI provider=\(next.rawValue)")
                })
    }

    /// 选择器里摆哪几档：三家云服务商，外加**他正在用的那一档**（否则选择器上没有一项
    /// 对得上，看着像被我们悄悄改掉了）
    private var offeredProviders: [LLMProvider] {
        var list: [LLMProvider] = [.openai, .deepseek, .qwen]
        if !list.contains(selected) { list.append(selected) }
        return list
    }

    // MARK: 段 3 Key（粘贴即验证）

    @ViewBuilder
    private var keySection: some View {
        // 全 App **唯一**的 Key 输入框：粘上即验证，验证通过才写钥匙串（见 KeyEntryView）
        KeyEntryView(provider: selected, model: polishModelBinding.wrappedValue, probe: keyProbe)
    }

    /// 这把 Key 用哪条链路验。开了云端识别的阿里云档直接打识别端点——
    /// 「模型有没有在百炼控制台开通」只有真调一次识别才验得到（/models 那一趟验不出来），
    /// 而那恰恰是 4.0.0 最常见的那个 403。其余一律走润色那条链路。
    private var keyProbe: KeyVerifier.Probe {
        (selected == .qwen && engineChoice == .cloudAlibaba) ? .cloudASR(.alibaba) : .llm
    }

    private var keyInfo: String {
        LLMCatalog.keyStorageNote + "\n" + LLMCatalog.newAccountNote
            + (keyProbe == .llm ? "" : "\n" + tr("开着云端识别，所以这把 Key 直接拿识别端点验：先找出你的接入地址（只查型号清单，不花钱），再发 1 秒合成音，连模型有没有在控制台开通一起验到，这一秒的费用可以忽略。",
                                                 "With cloud recognition on, the key is verified against the recognition endpoint: first your API host is found (a free model-list request), then one second of synthetic tone is sent, which also proves the model is enabled. The cost of that second is negligible."))
    }

    /// 云端识别那一段的细则：上传、计费、留存、先开通模型、出错回落。
    /// 这几句只出现在做这个选择的地方（PrivacyCopy 的云端那一组从不进关于页）。
    private var cloudRecognitionInfo: String {
        PrivacyCopy.cloudAlibabaLines.joined(separator: "\n")
    }

    // MARK: 段 5 关于我 / 自定义规则

    @ViewBuilder
    private var personalFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("关于我（可选）：", "About me (optional):"))
            TextEditor(text: $aboutMe)
                .font(.system(size: 12))
                .frame(height: 50)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("自定义规则（可选）：", "Custom rules (optional):"))
            TextEditor(text: $customRules)
                .font(.system(size: 12))
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
            Caption(tr("润色和指令都会读这两个框", "Both boxes are read by polish and by commands"))
        }
    }

    private var personalInfo: String {
        tr("「关于我」例如：「署名用 Gen」「邮件偏正式、聊天随意」——按住说指令、草拟邮件时会代入这些信息。\n「自定义规则」例如：「邮件场景用正式语气」「英文术语保留原文不翻译」「数字用阿拉伯数字」。\n两个框的内容都会跟着请求发给服务商。",
           "About me, for example: “sign as Gen”, “formal in email, casual in chat” — voice commands use this when drafting emails and replies.\nCustom rules, for example: “formal tone for emails”, “keep English jargon untranslated”, “use Arabic numerals”.\nThe contents of both boxes go to your provider with the request.")
    }

    // MARK: 段 6 高级（默认折叠）

    @ViewBuilder
    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                modelFields
                Divider()
                costlySwitches
            }
            .padding(.top, 6)
        } label: {
            Text(tr("分开设型号、联网搜索、优先处理",
                    "Split models, web search, priority processing"))
        }
    }

    private var advancedInfo: String {
        let shared = tr("上面的「模型」下拉一次改两个型号；在这里可以把它们分开：润色每句话都要跑，求快求省；指令低频，求质量。右侧下拉是内置快选，「刷新」会问端点它当前有哪些型号；也可以手填任意型号名。",
                        "The Model drop-down above writes both model fields at once; here you can split them: polish runs on every sentence, so it wants speed and low cost, while commands are rare and want quality. The drop-down holds the built-in picks, Refresh asks the endpoint what it serves today, and you can always type any model name.")
        switch selected {
        case .openai:
            return shared + tr("\nluna 最便宜，terra 平衡，sol 旗舰，astra 最强也最贵。",
                               "\nluna is the cheapest, terra is balanced, sol is the flagship, astra is the strongest and the priciest.")
        case .deepseek:
            return shared + tr("\ndeepseek-flash 快且便宜，润色时 MicType 会替你关掉思考模式；deepseek-v4-pro 更强。",
                               "\ndeepseek-flash is fast and cheap — MicType turns thinking mode off for polish; deepseek-v4-pro is stronger.")
        case .qwen:
            return shared + tr("\nqwen3.8-flash / qwen3.8-max 是当前代；qwen-flash / qwen-plus / qwen-max 是稳定别名，换代时自动指向新模型。",
                               "\nqwen3.8-flash / qwen3.8-max are the current generation; qwen-flash / qwen-plus / qwen-max are stable aliases that follow each new generation.")
        case .custom:
            return shared + tr("\n这一档没有内置清单：型号名照服务商文档填，或点「刷新」。",
                               "\nNo built-in list here: type the model id from your provider's docs, or hit Refresh.")
        case .local:
            return shared + tr("\n填你本机已经拉下来的模型名，例如 Ollama 里的 llama3.1:8b。",
                               "\nUse the model you have pulled locally, such as llama3.1:8b in Ollama.")
        }
    }

    // MARK: 高级 · 分开设型号

    @ViewBuilder
    private var modelFields: some View {
        ModelField(label: tr("润色模型", "Polish model"),
                   text: polishModelBinding, presets: modelChoices,
                   testing: testing, refreshing: refreshing,
                   onTest: { runModelTest(tr("润色模型", "Polish model"), polishModelBinding.wrappedValue) },
                   onRefresh: refreshModelList)
        ModelField(label: tr("指令模型", "Command model"),
                   text: commandModelBinding, presets: modelChoices,
                   testing: testing, refreshing: refreshing,
                   onTest: { runModelTest(tr("指令模型", "Command model"), commandModelBinding.wrappedValue) },
                   onRefresh: refreshModelList)
        Caption(tr("润色求快求省，指令求质量", "Polish wants speed and cost; commands want quality"))
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

    // MARK: 高级 · 两个花钱的开关（默认都关）

    @ViewBuilder
    private var costlySwitches: some View {
        Toggle(tr("语音指令允许联网搜索", "Let voice commands search the web"), isOn: $webSearch)
            .disabled(searchStyle == .unsupported)
        // 代价写在开关旁边：这两条是**价格**，不是解释，绝不搬进 ⓘ 里
        Caption(searchStyle == .unsupported
                ? tr("此服务商不支持。", "This provider does not support it.")
                : LLMCatalog.webSearchPriceNote)

        Toggle(tr("优先处理（token 单价 2 倍）", "Priority processing (2x token price)"), isOn: $fastTier)
            .disabled(selected != .openai)
        Caption(LLMCatalog.fastTierPriceNote
                + (selected == .openai ? "" : tr("　只有 OpenAI 有这个档位。", " Only OpenAI offers this tier.")))
        // 这一行的用途是揭发"勾了优先处理却被服务商降回普通档"。开关关着的时候它无事可揭
        if fastTier, let tier = lastServiceTier {
            let ranFast = LLMCatalog.servedPriorityTier(tier)
            Caption(tr("上一次请求实际跑在：", "Last request actually ran at: ")
                    + LLMCatalog.serviceTierName(tier),
                    warning: !ranFast)
        }
    }

    /// 最近一轮拿到过 service_tier 的记录。勾了优先处理却写着 default = 被服务商降级了，
    /// 这件事必须看得见——不然用户以为多付的钱买到了低延迟。
    private var lastServiceTier: String? {
        metrics.items.compactMap(\.serviceTier).first
    }

    // MARK: 动作

    /// 单个模型的连通性/速度测试。**不再顺手保存 Key**：Key 只由「服务商」段验证通过后写钥匙串。
    private func runModelTest(_ name: String, _ model: String) {
        testing = true
        testResult = ""
        LLMClient.testModel(model) { ok, message in
            testing = false
            testResult = name + tr("（", " (") + model + tr("）", ")") + tr("：", ": ")
                + (ok ? "✓ " : "✗ ") + message
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
                                   "The endpoint returned no model list - the built-in picks are unchanged")
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
            }
            .onAppear { runIntent(proxy: proxy) }
            .onChange(of: nav.visitCount) { _, _ in runIntent(proxy: proxy) }
        }
        .onChange(of: l10n.language) { _, _ in
            updateStatus = ""  // 一次性状态文字是语言快照，切语言即清空
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
            Text(tr("听写历史以明文保存在本机 Application Support 目录，最多 200 条：可在 设置 → 输入 关掉记录，或在菜单栏「最近记录」里清空、逐条删除。",
                    "Transcripts are kept in plain text on this Mac (up to 200): turn recording off in Settings → Input, or clear and delete them from Recent Transcripts in the menu bar."))
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
