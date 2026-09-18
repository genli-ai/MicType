import SwiftUI
import AppKit
import AVFoundation
import Combine

// MARK: - 首次启动引导

/// 五屏引导：两种手势 → 逐项权限 → 下模型 → 现场试一次 → 完成。
///
/// 为什么值得单独做一个窗口而不是塞进设置页：第一次打开的人不知道"轻点/按住"是两回事，
/// 也不知道要先下 860MB 模型；设置页是给已经会用的人改参数的，不是教人上手的。
/// 三条硬要求（都是过去踩过的坑）：
///   • 权限授予后自己变绿继续，绝不要求重启或"请再按一次"；
///   • 模型下载不阻塞界面，可取消、可跳过；
///   • 结尾必须能就地试一次——引导窗口自己是前台 App，正常插入链路原样可用。
enum OnboardingPage: Int, CaseIterable {
    case welcome
    case permissions
    case model
    case tryIt
    case done
}

/// 页码 + 权限状态：窗口控制器与各页共享的唯一状态源
final class OnboardingModel: ObservableObject {
    @Published var page: OnboardingPage = .welcome
    @Published var micOK = Permissions.microphoneGranted
    @Published var axOK = Permissions.isAccessibilityTrusted
    /// 权限页被用户明确跳过（跳过后 Continue 放行，但警告一直留着）
    @Published var skippedPermissions = false
}

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private var langObserver: AnyCancellable?
    private let model = OnboardingModel()

    /// 打开引导。startAt 用于"模型缺失"这类定点跳转（直接落到下载页）。
    func show(startAt page: OnboardingPage = .welcome) {
        model.page = page
        model.micOK = Permissions.microphoneGranted
        model.axOK = Permissions.isAccessibilityTrusted
        Log.info("Onboarding show page=\(page.rawValue)")

        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(model: model))
            let w = NSWindow(contentViewController: hosting)
            // 无边框标题：内容自己撑满，只留一个关闭按钮
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 560, height: 420))
            w.center()
            w.delegate = self
            window = w
            langObserver = L10n.shared.$language.sink { [weak self] lang in
                self?.window?.title = lang == .zh ? "欢迎使用 MicType" : "Welcome to MicType"
            }
        }
        window?.title = tr("欢迎使用 MicType", "Welcome to MicType")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func finish() {
        Settings.shared.onboardingCompleted = true
        Log.info("Onboarding finished")
        window?.close()
    }

    /// 中途点红叉也算"看过了"：不纠缠用户，设置页里随时能重新打开。
    func windowWillClose(_ notification: Notification) {
        if !Settings.shared.onboardingCompleted {
            Settings.shared.onboardingCompleted = true
            Log.info("Onboarding dismissed at page=\(model.page.rawValue)")
        }
    }
}

// MARK: - 主界面

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.page {
                case .welcome: WelcomePage()
                case .permissions: PermissionsPage(model: model)
                case .model: ModelPage(model: model)
                case .tryIt: TryItPage()
                case .done: DonePage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 8)

            Divider()
            footer
        }
        .frame(width: 560, height: 420)
    }

    // MARK: 底部导航

    private var footer: some View {
        HStack(spacing: 10) {
            if model.page != .welcome {
                Button(tr("上一步", "Back")) { step(-1) }
            }
            Spacer()
            dots
            Spacer()
            if model.page == .permissions && !bothGranted && !model.skippedPermissions {
                Button(tr("暂时跳过", "Skip for now")) {
                    model.skippedPermissions = true
                    Log.warn("Onboarding permissions skipped mic=\(model.micOK) ax=\(model.axOK)")
                }
            }
            Button(model.page == .done ? tr("开始使用", "Start Using MicType")
                                       : tr("继续", "Continue")) {
                if model.page == .done {
                    OnboardingWindowController.shared.finish()
                } else {
                    step(1)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(continueDisabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingPage.allCases, id: \.rawValue) { page in
                Circle()
                    .fill(page.rawValue == model.page.rawValue
                          ? Color.accentColor
                          : Color.secondary.opacity(page.rawValue < model.page.rawValue ? 0.5 : 0.22))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var bothGranted: Bool { model.micOK && model.axOK }

    /// 只有权限页会拦人：两项权限没齐，后面的「试一次」必然失败，先拦住比让他白试一次好。
    private var continueDisabled: Bool {
        model.page == .permissions && !bothGranted && !model.skippedPermissions
    }

    private func step(_ delta: Int) {
        let next = max(0, min(OnboardingPage.allCases.count - 1, model.page.rawValue + delta))
        guard let page = OnboardingPage(rawValue: next) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { model.page = page }
    }
}

// MARK: - 1. 欢迎

private struct WelcomePage: View {
    @ObservedObject private var l10n = L10n.shared

    private var key: String { Settings.shared.hotkey.shortSymbol }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
            Text(tr("用一个键说话，文字直接落在光标处。",
                    "Press one key, speak, and the text lands at your cursor."))
                .font(.system(size: 16, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 14) {
                GestureCard(symbol: "hand.tap",
                            gesture: tr("轻点 \(key)", "Tap \(key)"),
                            title: tr("本地听写", "Dictate"),
                            detail: tr("说什么，打什么。识别全在本机完成，音频不出这台 Mac。",
                                       "Exactly what you said, typed out. Recognition runs on-device; audio never leaves this Mac."))
                GestureCard(symbol: "hand.tap.fill",
                            gesture: tr("按住 \(key) 说", "Hold \(key)"),
                            title: tr("语音指令", "Command"),
                            detail: tr("改写选中的文字、帮你起草回复、或直接下一条指令；松手执行。",
                                       "Rewrite the selection, draft a reply, or just give an instruction; release to run."))
            }

            Text(tr("两种手势泾渭分明——MicType 从不猜你想要哪一种。",
                    "Two gestures, no guessing — MicType never infers which one you meant."))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GestureCard: View {
    let symbol: String
    let gesture: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundColor(.accentColor)
                Text(gesture)
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
}

// MARK: - 2. 权限

private struct PermissionsPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    /// 1 秒一次的轮询：用户在系统设置里打开开关后，这里自己变绿，不需要重启、也不必再点一次
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("两项系统权限", "Two system permissions"))
                .font(.system(size: 16, weight: .semibold))
            Text(tr("授权后这一页会自己变绿，不用重启 MicType。",
                    "The badges turn green on their own once granted — no restart needed."))
                .font(.caption)
                .foregroundColor(.secondary)

            PermissionRow(title: tr("麦克风", "Microphone"),
                          detail: tr("录下你说的话，用于本机识别。", "Records your voice for on-device recognition."),
                          ok: model.micOK) {
                Permissions.ensureMicrophone { granted in
                    model.micOK = granted
                    // notDetermined 以外的状态系统不再弹窗，只能引导去设置里手动开
                    if !granted { Permissions.openMicrophoneSettings() }
                }
            }

            PermissionRow(title: tr("辅助功能", "Accessibility"),
                          detail: tr("监听快捷键，并把文字粘贴到光标处。", "Listens for the hotkey and pastes text at your cursor."),
                          ok: model.axOK) {
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            }

            if !(model.micOK && model.axOK) {
                Text(tr("在系统设置的列表里勾选 MicType 即可。若列表里已勾选但这里仍是红叉，是旧授权失效了：选中 MicType 点「−」删掉，再点「+」加回来。",
                        "Tick MicType in the System Settings list. If it is already ticked but still shows red, the old grant is stale: select MicType, press “−”, then add it back with “+”."))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.skippedPermissions && !(model.micOK && model.axOK) {
                Text(tr("已跳过：在权限补齐之前，快捷键和文字插入都不会工作。",
                        "Skipped: the hotkey and text insertion will not work until both are granted."))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(timer) { _ in
            model.micOK = Permissions.microphoneGranted
            model.axOK = Permissions.isAccessibilityTrusted
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let ok: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 17))
                .foregroundColor(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if ok {
                Text(tr("已授权", "Granted"))
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Button(tr("打开设置", "Open Settings"), action: action)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
}

// MARK: - 3. 识别模型

private struct ModelPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var downloader = QwenModelDownloader.shared
    @AppStorage(SettingsKeys.qwenModelRepo) private var repo = QwenModels.defaultRepo
    @State private var refreshTick = 0
    /// 只有"这一页点下载"完成后才自动翻页；进页时模型就在的老用户留在原地，否则上一步就回不来了
    @State private var downloadStarted = false

    private var modelExists: Bool {
        _ = refreshTick
        let dir = QwenModels.localDirectory(for: repo)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("下载识别模型", "Download the speech model"))
                .font(.system(size: 16, weight: .semibold))
            Text(tr("Qwen3-ASR 在你的 Mac 上本地运行：约 30 种语言、22 种中文方言，识别过程不联网。只需下载一次。",
                    "Qwen3-ASR runs locally on your Mac: ~30 languages and 22 Chinese dialects, with no network during recognition. It downloads once."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(tr("模型：", "Model:"), selection: $repo) {
                ForEach(QwenModels.all, id: \.repo) { option in
                    Text("\(option.title) · \(option.sizeNote)").tag(option.repo)
                }
            }
            .disabled(downloader.isDownloading)

            HStack(spacing: 10) {
                Image(systemName: modelExists ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 17))
                    .foregroundColor(modelExists ? .green : .orange)
                Text(modelExists ? tr("模型已就绪 ✓", "Model ready ✓")
                                 : tr("模型未下载", "Model not downloaded"))
                    .font(.system(size: 13))
                Spacer()
                if downloader.isDownloading {
                    Button(tr("取消", "Cancel")) { downloader.cancel() }
                } else if !modelExists {
                    Button(tr("下载模型", "Download Model")) {
                        downloadStarted = true
                        QwenEngine.shared.unloadModel()
                        downloader.download(repo: repo)
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)

            if downloader.isDownloading {
                ProgressView(value: downloader.progress)
            }
            if !downloader.statusText.isEmpty {
                Text(downloader.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Text(tr("下载在后台进行，可以随时取消；中断后重新下载会接着没下完的文件继续。",
                    "The download runs in the background and can be cancelled; resuming picks up where it stopped."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(downloader.$isDownloading) { downloading in
            refreshTick += 1
            guard !downloading, downloadStarted else { return }
            // 下完了才继续：顺手预热模型，下一页"现场试一次"就不用干等冷启动
            let dir = QwenModels.localDirectory(for: repo)
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path) else { return }
            downloadStarted = false
            QwenEngine.shared.preload()
            Log.info("Onboarding model download complete, advancing")
            withAnimation(.easeInOut(duration: 0.15)) { model.page = .tryIt }
        }
        .onChange(of: repo) { _, _ in
            QwenEngine.shared.unloadModel()
            refreshTick += 1
        }
        .onChange(of: l10n.language) { _, _ in
            if !downloader.isDownloading { downloader.statusText = "" }
        }
    }
}

// MARK: - 4. 现场试一次

private struct TryItPage: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var text = ""
    @FocusState private var editorFocused: Bool

    private var key: String { Settings.shared.hotkey.shortSymbol }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("现在试一次", "Try it right now"))
                .font(.system(size: 16, weight: .semibold))
            Text(tr("光标已经在下面的框里。轻点 \(key)，说一句话，再轻点一次结束——文字会直接落进来。",
                    "The cursor is already in the box below. Tap \(key), say something, then tap again to finish — the text lands right here."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(size: 13))
                .focused($editorFocused)
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.35)))

            HStack {
                Text(tr("录音中按 Esc 可以取消。", "Press Esc while recording to cancel."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if !text.isEmpty {
                    Button(tr("清空", "Clear")) {
                        text = ""
                        editorFocused = true
                    }
                    .controlSize(.small)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("AI 润色与语音指令是可选的：填一个 API Key 才会启用。不填也能一直用纯听写。",
                            "AI polish and voice commands are optional: they need an API key. Without one, plain dictation keeps working."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(tr("打开设置", "Open Settings")) {
                        SettingsWindowController.shared.show()
                    }
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // 稍等一拍再抢焦点：窗口刚翻页时 TextEditor 还没进响应链，立刻 focus 会落空
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { editorFocused = true }
        }
    }
}

// MARK: - 5. 完成

private struct DonePage: View {
    @ObservedObject private var l10n = L10n.shared

    private var key: String { Settings.shared.hotkey.shortSymbol }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.green)
            Text(tr("可以开始用了", "You're ready"))
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                TipRow(symbol: "hand.tap",
                       text: tr("轻点 \(key) 听写，再轻点一次结束。",
                                "Tap \(key) to dictate, tap again to finish."))
                TipRow(symbol: "hand.tap.fill",
                       text: tr("按住 \(key) 说指令，松手执行。",
                                "Hold \(key) to speak a command, release to run it."))
                TipRow(symbol: "menubar.arrow.up.rectangle",
                       text: tr("菜单栏的麦克风图标里有历史记录、润色档位和设置。",
                                "The menu-bar mic icon holds your history, polish mode and settings."))
                TipRow(symbol: "text.book.closed",
                       text: tr("人名、术语老是听错？在 设置 → 识别 的词汇表里填「错写=正写」，一次搞定。",
                                "Names or jargon misheard? Add \"wrong=right\" to the vocabulary in Settings → Recognition."))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(tr("随时可以在 设置 → 通用 里重新打开这份引导。",
                    "You can reopen this guide any time from Settings → General."))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TipRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
