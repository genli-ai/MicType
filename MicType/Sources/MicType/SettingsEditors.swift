import SwiftUI
import AppKit
import ServiceManagement
import Combine

// MARK: - 设置正页（5.0.0 起**整个设置就是这一页**）

/// ```
/// 麦克风还没授权，录不到声音                    [打开麦克风设置]   ← 只在缺权限时出现
/// 辅助功能没授权：热键和输入都无效              [打开辅助功能设置]
///
/// 服务商    [OpenAI | 阿里云]                            正在使用 ✓
/// API Key   [••••••••]  [去申请 Key ↗]                          ⓘ
/// API Host  [百炼控制台里的接入地址]              ← 只有阿里云这一档
/// 已连通 ✓ 阿里云 · qwen3.8-flash · 约 $0.2/小时   ← 状态行，只在有话说时出现
/// ─────────────────────────────────────────────────────
///            关于 · 写作偏好 · 检查更新 · 重看引导
/// ```
///
/// 4.x 拿掉了什么、为什么，见 SettingsRoute 的注释。这一页自己的三条纪律：
///   • **整页只有一颗 ⓘ**（API Key 那一行）：Key 存钥匙串、费用直付、这一家每小时大概
///     多少钱、阿里云多一句"接入地址留空就自动找"。别的都不值得一颗要点开的气泡。
///   • 服务商点一下只是**预览**，钥匙串里有 Key 才真正采纳（AISetup.adoptsProvider）——
///     这条 4.1.1 起的规矩一个字没改：点着挨个看看的人不该把自己从一把好 Key 上换走。
///   • 权限横幅只在**缺项时**出现：两项都齐的时候，它每天占着首屏最贵的位置说一句"没事"。
struct MainSettingsPage: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.llmProvider) private var provider = LLMProvider.openai.rawValue
    @AppStorage(SettingsKeys.openaiBaseURL) private var baseURL = "https://api.openai.com/v1"
    @AppStorage(SettingsKeys.qwenAPIHost) private var qwenAPIHost = ""
    @AppStorage(SettingsKeys.qwenResolvedHost) private var qwenResolvedHost = ""
    /// 钥匙串不是 @AppStorage，删掉一把 Key 之后这一页不会自己重算。
    /// 这个计数器就是那一下"手动推一把"（只影响显示，不落盘）。
    @State private var keychainTick = 0
    /// 选择器上**正在看**的那一档，不是生效的那一档（见 adoptIfUsable）
    @State private var pendingProvider = Settings.shared.llmProvider

    @State private var micOK = Permissions.microphoneGranted
    @State private var axOK = Permissions.isAccessibilityTrusted
    /// 权限轮询：用户是去系统设置里勾的，勾完不会回来通知我们。
    /// **只在这扇窗开着的时候轮**（窗口是复用的，关掉之后这一页并不会消失）。
    @State private var permissionPoll: AnyCancellable?
    @ObservedObject private var windowState = SettingsWindowController.shared

    /// 选择器上看着的那一档
    private var selected: LLMProvider { pendingProvider }
    /// 真正生效的那一档（「正在使用 ✓」按它算）
    private var inUseProvider: LLMProvider { LLMProvider(rawValue: provider) ?? .openai }

    /// 选择器上**看着**的这一档钥匙串里有没有 Key。只用来判"这一档是不是还没配"。
    private var hasStoredKey: Bool {
        _ = keychainTick
        return KeychainHelper.loadAPIKey(account: selected.keychainAccount) != nil
    }

    /// 某一档这一刻的 Base URL。**从 @AppStorage 的值推**而不是读 Settings.currentBaseURL：
    /// 后者不是 @Published，改了接入地址界面不会重算。
    private func effectiveBaseURL(for provider: LLMProvider) -> String {
        switch provider {
        case .openai: return baseURL
        case .qwen:
            // 接入地址是试出来的：粘了就用粘的，否则用试通的那台（见 AlibabaEndpoint）
            let host = AlibabaEndpoint.normalizeHost(qwenAPIHost)
                ?? AlibabaEndpoint.normalizeHost(qwenResolvedHost)
            return host.map { AlibabaEndpoint.compatibleBaseURL(host: $0) } ?? Settings.shared.qwenBaseURL
        }
    }

    var body: some View {
        // MeasuredFormPage：窗口高度跟着这一页的内容走（见 SettingsWindowSizing）
        MeasuredFormPage(route: .overview) {
            Form {
                if !micOK || !axOK {
                    Section { permissionsBanner }
                }
                // 服务商 → Key →（阿里云的）接入地址：与引导 ③ **同一个视图**
                // （CloudSetupCore），顺序、标题、说明、那颗 ⓘ 全都只写一处。
                CloudSetupCore(style: .settings,
                               selected: selected,
                               inUse: inUseProvider,
                               provider: providerBinding,
                               showsNotSetUpHint: !hasStoredKey,
                               onKeyStatus: { _ in
                                   // 钥匙串不是 @AppStorage：验证通过之后这一页要自己重算，
                                   // 并且立刻把这一档采纳为生效服务商
                                   keychainTick &+= 1
                                   adoptIfUsable(selected)
                               }) {
                    providerNotices
                }
                Section { footer }
            }
            .formStyle(.grouped)
            // 回到这一页时选择器要停在**正在用**的那一档上（上一次可能只是预览到一半就走了）
            .onAppear {
                pendingProvider = inUseProvider
                startPermissionPolling()
            }
            .onDisappear { stopPermissionPolling() }
            // 关窗时这一页并不会被销毁（窗口复用），所以停轮询这件事只能由窗口来说
            .onChange(of: windowState.isOpen) { _, open in
                if open { startPermissionPolling() } else { stopPermissionPolling() }
            }
            // 从系统设置回来（刚勾完权限）时重问一次
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
        }
    }

    /// 服务商下面的边界状态。正常情况下这里一个字都不显示。
    @ViewBuilder
    private var providerNotices: some View {
        // OpenAI 的地址被老版本（或导入的设置文件）改过时必须看得见：
        // 看不见的自定义地址是查不出来的故障——而它还会让云端识别整条实时链路失效
        // （实时地址是写死的官方域名，见 CloudASRSettings.openAIUsesOfficialEndpoint）。
        if selected == .openai, effectiveBaseURL(for: .openai) != LLMProvider.openai.defaultBaseURL {
            BoundaryRow(text: SettingsCopy.endpointOverridden + effectiveBaseURL(for: .openai)) {
                Button(tr("恢复官方地址", "Restore the official URL")) {
                    baseURL = LLMProvider.openai.defaultBaseURL
                }
            }
        }
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
    }

    private func startPermissionPolling() {
        guard permissionPoll == nil else { return }
        refreshPermissions()
        permissionPoll = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { _ in refreshPermissions() }
    }

    private func stopPermissionPolling() {
        permissionPoll?.cancel()
        permissionPoll = nil
    }

    private func refreshPermissions() {
        micOK = Permissions.microphoneGranted
        axOK = Permissions.isAccessibilityTrusted
    }

    // MARK: 脚注：四个链接，一颗按钮都没有

    /// 「重看引导」住在这里（用户 2026-09-20 拍板）：那份引导讲的是整个产品怎么用，
    /// 不是一条设置。「写作偏好」4.3.3 之前是「输入」页上的一段，5.0.0 起从这里点开
    /// ——它改得不勤，但改的是用户自己的文字，值一个自己的地方。
    private var footer: some View {
        HStack(spacing: 16) {
            Button(tr("关于 MicType", "About MicType")) {
                SettingsNavigator.shared.go(to: .about)
            }
            Button(tr("写作偏好", "Writing preferences")) {
                SettingsNavigator.shared.go(to: .writing)
            }
            Button(tr("检查更新", "Check for Updates")) {
                SettingsNavigator.shared.go(to: .about, intent: .checkUpdate)
            }
            Button(tr("重看引导", "Review the guide")) {
                OnboardingWindowController.shared.show()
            }
            Spacer()
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    // MARK: 换服务商

    /// **只换"正在看"的那一档**，真正生效要等 adoptIfUsable 认可。
    private var providerBinding: Binding<LLMProvider> {
        Binding(get: { selected },
                set: { next in
                    guard next != selected else { return }
                    pendingProvider = next
                    keychainTick &+= 1
                    Log.info("AI provider previewed=\(next.rawValue)")
                    // 钥匙串里已经有这一档的 Key（换回上一家、或早就配过）就当场生效，
                    // 不必再逼他重粘一次
                    adoptIfUsable(next)
                })
    }

    /// 只有"这一档真的能用"才把它写成生效的服务商（判据是纯函数 AISetup.adoptsProvider，
    /// 与引导 ③ 同一条）。换过去之后识别也跟着换家——那是 5.0.0 的推导，不是一条设置。
    private func adoptIfUsable(_ next: LLMProvider) {
        let hasKey = KeychainHelper.loadAPIKey(account: next.keychainAccount) != nil
        guard AISetup.adoptsProvider(current: inUseProvider, next: next,
                                     requiresKey: next.requiresAPIKey, hasKey: hasKey,
                                     polishModel: LLMCatalog.defaultModel(for: next)) else { return }
        provider = next.rawValue
        Log.info("AI provider adopted=\(next.rawValue) (recognition follows)")
    }
}

// MARK: - 写作偏好（从设置底部那排小字点开）

/// 两个框：专有词汇表、自定义规则。**5.0.0 起它们住在自己的一页上**——
/// 4.3.3 到 4.3.6 期间它们和快捷键、界面语言、开机自启挤在「输入」页里，
/// 而那一页其余的东西这一版全都走出厂默认了（设计文档第 1 节）。
///
/// 为什么不并进设置正页：那一页是"发给谁"，这一页是"我的话该怎么被写出来"——
/// 后者改得不勤（词表是攒出来的），但改的是用户自己的文字，值一个自己的地方。
struct WritingPreferencesEditor: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.customVocabulary) private var vocabulary = ""
    @AppStorage(SettingsKeys.customPolishRules) private var customRules = ""

    var body: some View {
        MeasuredFormPage(route: .writing) {
            Form {
                Section {
                    // 这一页开头唯一一句解释：它回答的是"这两个框是干什么的"
                    Caption(SettingsCopy.writingPreferencesIntro)

                    // ——— 词汇表
                    SectionHeader(title: tr("专有词汇表（逗号或换行分隔）",
                                            "Custom vocabulary (comma or newline separated)"),
                                  info: SettingsCopy.vocabularyInfo)
                    TextEditor(text: $vocabulary)
                        .font(.system(size: 12))
                        .frame(height: 76)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                    // 这条提示就摆在词汇表这一段里：它要用户做的动作正是"往上面这个框里填词"
                    Caption(SettingsCopy.vocabularyHardReplace)

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
                }
            }
            .formStyle(.grouped)
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
                    // 菜单栏那枚图标长什么样（4.3.4 加）：这个应用平时只以那枚图标存在，
                    // 而"找不到它在哪"正是 2026-09-22 反馈里最靠前的一条。
                    // 和引导最后一屏**同一张图**（MenuBarIcon），不另画一份
                    HStack(spacing: 8) {
                        Image(nsImage: MenuBarIcon.large())
                            .renderingMode(.template)
                            .foregroundColor(.accentColor)
                        Text(tr("菜单栏里认这个图标", "Look for this icon in the menu bar"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
            // 「存哪儿、多少条、不上传」那一句本身已经在上面那几句里了
            //（PrivacyCopy.historyStaysLocal 引用的就是 HistoryStore.storageNote），
            // 所以这里**只补"去哪儿清"**——5.0.0 之前这里把整句又渲染了一遍，
            // 同一件事在同一屏上出现两次
            Text(tr("在菜单栏「最近记录」里可以清空或逐条删除。",
                    "Clear them or delete them one by one from Recent Transcripts in the menu bar."))
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
