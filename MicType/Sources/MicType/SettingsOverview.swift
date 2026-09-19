import SwiftUI
import AppKit
import Combine
import ServiceManagement

// MARK: - 概览（设置窗口的首页）

/// 三张卡回答三个问题：按哪个键、这台 Mac 怎么听、有没有在花钱。
/// 每张卡只有标题 + 一句话 + 一颗「更改」——句子由 SettingsSummary 那几个纯函数拼
/// （单测钉死），这里只负责把当前状态喂进去。
///
/// 权限横幅只在缺项时出现：两项都齐的时候，它每天占着首屏最贵的位置说一句"没事"。
struct SettingsOverview: View {
    @ObservedObject private var l10n = L10n.shared

    // 输入
    @AppStorage(SettingsKeys.hotkey) private var hotkey = HotkeyChoice.rightOption.rawValue
    @AppStorage(SettingsKeys.overlayPosition) private var overlayPosition = OverlayPosition.bottomCenter.rawValue
    @AppStorage(SettingsKeys.playSounds) private var playSounds = true
    // 本地识别
    @AppStorage(SettingsKeys.recognitionLanguage) private var recognitionLanguage = RecognitionLanguages.autoCode
    @AppStorage(SettingsKeys.customVocabulary) private var vocabulary = ""
    @AppStorage(SettingsKeys.qwenModelRepo) private var qwenRepo = QwenModels.defaultRepo
    @AppStorage(SettingsKeys.inputDeviceUID) private var inputDeviceUID = ""
    // 云端 AI
    @AppStorage(SettingsKeys.polishLevel) private var polishLevel = PolishLevel.smart.rawValue
    @AppStorage(SettingsKeys.llmProvider) private var provider = LLMProvider.openai.rawValue
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue

    @ObservedObject private var downloader = QwenModelDownloader.shared
    @ObservedObject private var upgrader = ModelUpgrader.shared
    /// 模型目录到货时卡上那句话要跟着变（首启动时目录还在路上）
    @ObservedObject private var catalogStore = ModelCatalogStore.shared

    @State private var micOK = Permissions.microphoneGranted
    @State private var axOK = Permissions.isAccessibilityTrusted
    /// 钥匙串与"模型名/接入地址拼不拼得出来"都不是 @AppStorage，改完不会自己回来重算。
    /// 这两条在每次回到概览时重算（从「云端 AI」页返回会重建这一页）。
    @State private var keyState = SettingsSummary.KeyState.missing
    @State private var cloudModel = ""
    /// 指定麦克风的名字。CoreAudio 枚举不便宜，只在出现和设备变动时查一次
    @State private var micName = ""
    /// 权限轮询：用户去系统设置里勾上之后，我们这边没有任何通知，只能自己回头看。
    /// **只在这扇窗开着的时候轮**：窗口是复用的（isReleasedWhenClosed = false），关掉之后
    /// 这一页并不会消失，4.0.2 那个 autoconnect 的 Timer 于是一路跑到退出为止——每 2 秒
    /// 叫醒一次进程去问 tccd 和摄像头/麦克风授权，而屏幕上根本没有人在看这条横幅。
    @State private var permissionPoll: AnyCancellable?
    /// 登录项要问 ServiceManagement（它可能在系统设置里被改掉，不是我们的设置），那是一次
    /// XPC 往返。4.0.2 把它写成 computed property 摆在 body 里：下模型时进度每跳一下这一页
    /// 就重画一次，于是主线程上每一帧都在同步问 launchd。存起来，只在进这一页 / App 重新
    /// 激活（可能刚从系统设置回来）时问一次。
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// 这扇窗开着没有：关窗时要停掉上面那个轮询，再开时要接着轮
    @ObservedObject private var windowState = SettingsWindowController.shared

    private var selectedHotkey: HotkeyChoice { HotkeyChoice(rawValue: hotkey) ?? .rightOption }
    private var selectedOverlay: OverlayPosition { OverlayPosition(rawValue: overlayPosition) ?? .bottomCenter }
    private var selectedProvider: LLMProvider { LLMProvider(rawValue: provider) ?? .openai }
    private var engineChoice: RecognitionEngineChoice { RecognitionEngineChoice.parse(recognitionEngine) }
    private var selectedPolishLevel: PolishLevel { PolishLevel(rawValue: polishLevel) ?? .smart }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !micOK || !axOK { permissionsBanner }

                OverviewCard(title: tr("输入", "Input"),
                             card: SettingsSummary.Card(
                                sentence: SettingsSummary.inputSummary(hotkey: selectedHotkey,
                                                                       overlayPosition: selectedOverlay,
                                                                       sounds: playSounds,
                                                                       launchAtLogin: launchAtLogin),
                                badge: nil)) {
                    SettingsNavigator.shared.go(to: .input)
                }

                OverviewCard(title: tr("本地识别", "On-device recognition"),
                             card: recognitionCard) {
                    SettingsNavigator.shared.go(to: .recognition)
                }

                OverviewCard(title: tr("云端 AI", "Cloud AI"),
                             card: cloudCard) {
                    SettingsNavigator.shared.go(to: .cloud)
                }

                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            refreshLiveState()
            micName = Self.deviceName(uid: inputDeviceUID)
            startPermissionPolling()
        }
        .onDisappear { stopPermissionPolling() }
        .onChange(of: inputDeviceUID) { _, uid in
            micName = Self.deviceName(uid: uid)
        }
        // 关窗时这一页并不会被销毁（窗口复用），所以停轮询这件事只能由窗口来说
        .onChange(of: windowState.isOpen) { _, open in
            if open {
                refreshLiveState()
                startPermissionPolling()
            } else {
                stopPermissionPolling()
            }
        }
        // 从系统设置回来（勾权限、改登录项）时把要问系统的那几条重新问一遍
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLiveState()
            refreshPermissions()
        }
    }

    // MARK: 权限轮询的开关

    /// 只轮询权限：用户是去系统设置里勾的，勾完不会回来通知我们。
    /// 钥匙串与型号在概览这一页上改不动，每次回到概览时（onAppear）重算一次就够了
    private func startPermissionPolling() {
        guard permissionPoll == nil else { return }
        refreshPermissions()
        permissionPoll = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { _ in self.refreshPermissions() }
    }

    private func stopPermissionPolling() {
        permissionPoll?.cancel()
        permissionPoll = nil
    }

    private func refreshPermissions() {
        micOK = Permissions.microphoneGranted
        axOK = Permissions.isAccessibilityTrusted
    }

    // MARK: 三张卡的数据

    private var recognitionCard: SettingsSummary.Card {
        SettingsSummary.recognitionSummary(language: recognitionLanguage,
                                           vocabCount: Settings.parseVocabulary(vocabulary).terms.count,
                                           modelState: modelState,
                                           micName: micName)
    }

    /// 本机模型这一刻处在哪一档。下载中优先：那是唯一会自己动的状态。
    private var modelState: SettingsSummary.ModelState {
        let name = modelName
        if downloader.isDownloading {
            return .downloading(percent: Int((downloader.progress * 100).rounded()))
        }
        guard QwenModels.isFullyDownloaded(repo: qwenRepo) else { return .missing(name: name) }
        switch upgrader.decision {
        case .none: return .ready(name: name)
        // 三种提示的动作不同（换一档 / 重下同一份 / 先更新 App），但对概览是同一件事：
        // 「现在这份能用，不过有得换」——具体怎么换是编辑页里那张横幅的事
        case .upgrade, .refresh, .needsAppUpdate: return .upgradeAvailable(name: name)
        }
    }

    /// 模型在卡上的名字。目录里下架了就退回仓库名的最后一段——绝不显示空白
    private var modelName: String {
        _ = catalogStore.catalog
        if let option = QwenModels.all.first(where: { $0.repo == qwenRepo }) { return option.title }
        return qwenRepo.components(separatedBy: "/").last ?? qwenRepo
    }

    private var cloudCard: SettingsSummary.Card {
        SettingsSummary.cloudSummary(provider: selectedProvider,
                                     model: cloudModel,
                                     keyState: keyState,
                                     polishLevel: selectedPolishLevel,
                                     engine: engineChoice)
    }

    /// 钥匙串、登录项、拼不拼得出地址和型号：这几件事 @AppStorage 管不着，得自己来问一遍
    private func refreshLiveState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        cloudModel = Settings.shared.currentPolishModel
        guard LLMClient.isConfigured else {
            keyState = .missing
            return
        }
        keyState = LLMCatalog.aiReady(hasCredential: true,
                                      baseURL: Settings.shared.currentBaseURL,
                                      polishModel: cloudModel) ? .ready : .incomplete
    }

    private static func deviceName(uid: String) -> String {
        guard !uid.isEmpty else { return "" }
        return InputDevices.list().first { $0.uid == uid }?.name ?? ""
    }

    // MARK: 权限横幅（缺了才出现）

    /// 两项权限各一行、各一颗按钮：以前并排两个徽章却只有一个按钮，而且固定跳辅助功能面板——
    /// 麦克风是红叉的用户点几次都到同一页。
    private var permissionsBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !micOK {
                BoundaryRow(text: SettingsCopy.microphoneMissing) {
                    Button(tr("打开麦克风设置", "Open Microphone Settings")) {
                        Permissions.openMicrophoneSettings()
                    }
                }
            }
            if !axOK {
                BoundaryRow(text: SettingsCopy.accessibilityMissing) {
                    Button(tr("打开辅助功能设置", "Open Accessibility Settings")) {
                        Permissions.openAccessibilitySettings()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    // MARK: 脚注：三个链接，一颗按钮都没有

    private var footer: some View {
        HStack(spacing: 16) {
            Button(tr("关于 MicType", "About MicType")) {
                SettingsNavigator.shared.go(to: .about)
            }
            Button(tr("隐私", "Privacy")) {
                SettingsNavigator.shared.go(to: .about, intent: .privacy)
            }
            Button(tr("检查更新", "Check for Updates")) {
                SettingsNavigator.shared.go(to: .about, intent: .checkUpdate)
            }
            Spacer()
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.top, 2)
    }
}

// MARK: - 一张卡

/// 标题（+ 徽章）、一句话、一颗「更改」——三者共用一套内边距与基线，整张卡是**一个**对象。
/// 「更改」保持系统默认的按钮样式：键盘导航开着时它自带焦点环，自绘一套就把那圈环弄丢了。
private struct OverviewCard: View {
    let title: String
    let card: SettingsSummary.Card
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if let badge = card.badge {
                        BadgeChip(text: badge, level: card.level)
                    }
                }
                Text(card.sentence)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(tr("更改", "Change"), action: action)
                .fixedSize()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                // 半透明的 secondary：浅色下是淡灰，深色下自动变成提亮的一层，两种外观都不用各写一份
                .fill(Color.secondary.opacity(hovering ? 0.14 : 0.08))
        )
        // 悬停只动背景，不动尺寸：卡片一跳，整页跟着重排
        .onHover { hovering = $0 }
        .animation(SettingsNavigator.reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

/// 需要处理的那件事。只说动作，不复述状态——句子里已经讲过现在是什么样了。
/// 颜色由分量决定（SettingsSummary.BadgeLevel），不由调用方顺手挑。
private struct BadgeChip: View {
    let text: String
    let level: SettingsSummary.BadgeLevel

    private var tint: Color {
        switch level {
        case .attention: return .orange
        case .progress: return .accentColor
        }
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundColor(tint)
    }
}
