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
    /// 权限轮询：用户去系统设置里勾上之后，我们这边没有任何通知，只能自己回头看
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var selectedHotkey: HotkeyChoice { HotkeyChoice(rawValue: hotkey) ?? .rightOption }
    private var selectedOverlay: OverlayPosition { OverlayPosition(rawValue: overlayPosition) ?? .bottomCenter }
    private var selectedProvider: LLMProvider { LLMProvider(rawValue: provider) ?? .openai }
    private var engineChoice: RecognitionEngineChoice { RecognitionEngineChoice.parse(recognitionEngine) }
    private var usageMode: AIUsageMode {
        AISetup.mode(polishLevel: PolishLevel(rawValue: polishLevel) ?? .smart, engine: engineChoice)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !micOK || !axOK { permissionsBanner }

                OverviewCard(title: tr("输入", "Input"),
                             sentence: SettingsSummary.inputSummary(hotkey: selectedHotkey,
                                                                    overlayPosition: selectedOverlay,
                                                                    sounds: playSounds,
                                                                    launchAtLogin: launchAtLogin),
                             badge: nil) {
                    SettingsNavigator.shared.go(to: .input)
                }

                let recognition = recognitionCard
                OverviewCard(title: tr("本地识别", "On-device recognition"),
                             sentence: recognition.sentence,
                             badge: recognition.badge) {
                    SettingsNavigator.shared.go(to: .recognition)
                }

                let cloud = cloudCard
                OverviewCard(title: tr("云端 AI", "Cloud AI"),
                             sentence: cloud.sentence,
                             badge: cloud.badge) {
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
        }
        .onChange(of: inputDeviceUID) { _, uid in
            micName = Self.deviceName(uid: uid)
        }
        // 只轮询权限：用户是去系统设置里勾的，勾完不会回来通知我们。
        // 钥匙串与型号在概览这一页上改不动，每次回到概览时（onAppear）重算一次就够了
        .onReceive(refreshTimer) { _ in
            micOK = Permissions.microphoneGranted
            axOK = Permissions.isAccessibilityTrusted
        }
    }

    // MARK: 三张卡的数据

    /// 登录项的状态由 ServiceManagement 现问（它可能被系统设置里改掉，不是我们的设置）
    private var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

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
        SettingsSummary.cloudSummary(mode: usageMode,
                                     provider: selectedProvider,
                                     model: cloudModel,
                                     keyState: keyState,
                                     cloudRecognition: engineChoice == .cloudAlibaba)
    }

    /// 钥匙串 + 拼不拼得出地址和型号：这两件事 @AppStorage 管不着，得自己来问一遍
    private func refreshLiveState() {
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
                BoundaryRow(text: tr("麦克风还没授权：现在录不到任何声音。",
                                     "Microphone is not granted yet: nothing is recorded.")) {
                    Button(tr("打开麦克风设置", "Open Microphone Settings")) {
                        Permissions.openMicrophoneSettings()
                    }
                }
            }
            if !axOK {
                BoundaryRow(text: tr("辅助功能还没授权：热键和输入都用不了。",
                                     "Accessibility is not granted yet: no hotkey and no typing.")) {
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

private struct OverviewCard: View {
    let title: String
    let sentence: String
    let badge: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if let badge = badge { BadgeChip(text: badge) }
                }
                Text(sentence)
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
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

/// 需要处理的那件事。只说动作，不复述状态——句子里已经讲过现在是什么样了
private struct BadgeChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundColor(.orange)
    }
}
