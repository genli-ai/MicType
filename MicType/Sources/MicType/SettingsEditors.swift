import SwiftUI
import AppKit
import ServiceManagement
import Combine

// MARK: - 设置正页（5.3.0 起是一张**状态页**）

/// ```
/// 麦克风还没授权，录不到声音                    [打开麦克风设置]   ← 只在缺权限时出现
///
/// ┌ [图标] OpenAI · 已连接                               本周 ┐
/// │        Key ···7f3a                                        │
/// │ ───────────────────────────────────────────────────────── │
/// │ 43 分钟            6,200 字            约 $0.12            │
/// └───────────────────────────────────────────────────────────┘
/// ┌ OpenAI Key  [••••••••]  [去申请 Key ↗]                 ⓘ ┐
/// │ 写作偏好    词汇表 12 条 · 规则 2 条                     › │
/// │ 界面语言    中文                                         › │
/// └───────────────────────────────────────────────────────────┘
///          关于 · 隐私 · 检查更新 · 重看引导 · 历史记录
/// ```
///
/// 为什么从「配置页」变成「状态页」（UX 方案 §3 D，用户 2026-09-29 拍板）：打开设置的人最想知道的
/// 是三件事——连上了没有、这周用了多少、大概花了多少钱；而要改的东西只剩一把 Key。
/// 5.2.0 打开设置只看到一个 Key 框，"它为我做了什么"一个字都没有。
///
/// 这一页自己的纪律：
///   • **5.1.0 起只有 OpenAI 一家**：没有服务商那一行，栏名就叫「OpenAI Key」；
///   • 用量是**本机账本**算的（UsageStore，永不上传），费用一律写「约」；
///   • 权限横幅只在**缺项时**出现：两项都齐的时候，它每天占着首屏最贵的位置说一句"没事"；
///   • 跟系统外观走（Theme.palette）：浅色模式下是浅色 tokens，不是反色。
struct MainSettingsPage: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var usage = UsageStore.shared
    @AppStorage(SettingsKeys.openaiBaseURL) private var baseURL = "https://api.openai.com/v1"
    @AppStorage(SettingsKeys.customVocabulary) private var vocabulary = ""
    @AppStorage(SettingsKeys.customPolishRules) private var customRules = ""
    @Environment(\.colorScheme) private var scheme

    /// 上半那一叠量出来有多高、底栏有多高。两个数加起来才是这一页要报给窗口的高度
    @State private var bodyHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    @State private var micOK = Permissions.microphoneGranted
    @State private var axOK = Permissions.isAccessibilityTrusted
    /// 权限轮询：用户是去系统设置里勾的，勾完不会回来通知我们。
    /// **只在这扇窗开着的时候轮**（窗口是复用的，关掉之后这一页并不会消失）。
    @State private var permissionPoll: AnyCancellable?
    @ObservedObject private var windowState = SettingsWindowController.shared

    /// 钥匙串里那把 Key 的尾号（nil = 没有 Key）。**存着**而不是在 body 里现读：
    /// 读钥匙串是 Security 框架的调用，不许坐在每次重绘的路径上（Settings.swift 里那条规矩）。
    /// 刷新点：这一页出现、Key 验证有了结论
    @State private var keyTail: String?

    /// 这一页要报给窗口的高度：内容本身，没有地板（5.0.5 的教训）
    private var naturalHeight: CGFloat {
        // +1：底栏上面那条 Divider
        bodyHeight + footerHeight + 1
    }

    var body: some View {
        let palette = Theme.palette(scheme)
        VStack(spacing: 0) {
            // 上半：卡片。**滚动容器占满剩下的高度**，所以底栏永远贴着窗底
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !micOK || !axOK {
                        MTCard { permissionsBanner }
                    }
                    SettingsStatusCard(keyTail: keyTail, week: usage.thisWeek())
                    rowsCard
                }
                .padding(20)
                .frame(width: SettingsWindowSizing.width)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geo in
                    Color.clear.onAppear { bodyHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, height in bodyHeight = height }
                })
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(GeometryReader { geo in
                    Color.clear.onAppear { footerHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, height in footerHeight = height }
                })
        }
        .frame(width: SettingsWindowSizing.width)
        .background(palette.bg)
        .foregroundColor(palette.text)
        .preference(key: SettingsPageHeightKey.self, value: [.overview: naturalHeight])
        .onAppear {
            refreshKeyTail()
            startPermissionPolling()
        }
        .onDisappear { stopPermissionPolling() }
        // 关窗时这一页并不会被销毁（窗口复用），所以停轮询这件事只能由窗口来说
        .onChange(of: windowState.isOpen) { _, open in
            if open {
                refreshKeyTail()
                startPermissionPolling()
            } else {
                stopPermissionPolling()
            }
        }
        // 从系统设置回来（刚勾完权限）时重问一次
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
    }

    // MARK: 下面那张卡：三行

    private var rowsCard: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 0) {
                providerNotices
                // Key：与引导 ② **同一个控件**（CloudSetupCore → KeyEntryView），验证与存储只写一处
                CloudSetupCore(style: .settings,
                               onKeyStatus: { _ in refreshKeyTail() }) {
                    EmptyView()
                }
                .padding(.vertical, 6)
                rowDivider
                writingRow
                rowDivider
                languageRow
            }
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06))
            .frame(height: 1)
    }

    /// 「写作偏好」一行：值是事实（几条词、几条规则），点进去是那一页编辑器
    private var writingRow: some View {
        Button {
            SettingsNavigator.shared.go(to: .writing)
        } label: {
            SettingsFieldRow(label: SettingsCopy.vocabularyPageTitle) {
                HStack {
                    Text(WritingPreferencesSummary.line(vocabulary: vocabulary, rules: customRules))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    chevron
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 「界面语言」一行：点一下弹一个两项的小菜单、当前那项打勾，**选了才切**
    ///（5.0.2 的规矩：误点一次的人不该要在他看不懂的界面里找回来）
    private var languageRow: some View {
        SettingsFieldRow(label: tr("界面语言", "Language")) {
          HStack(spacing: 0) {
            Menu {
                Picker("", selection: Binding(get: { l10n.language },
                                              set: { next in
                                                  guard next != l10n.language else { return }
                                                  Log.info("UI language switched to=\(next.rawValue)")
                                                  l10n.language = next
                                              })) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(l10n.language.displayName)
            }
            // .button + .plain：标签就是一行普通的字。.borderlessButton 会把标签画粗、
            // 还自带一枚箭头挤在字前面（5.3.0 首版快照里的「> 中文」）
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer(minLength: 8)
            chevron
          }
        }
        .frame(minHeight: 44)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Theme.palette(scheme).muted)
            .accessibilityHidden(true)
    }

    /// Key 上面的边界状态。正常情况下这里一个字都不显示。
    @ViewBuilder
    private var providerNotices: some View {
        // OpenAI 的地址被老版本（或导入的设置文件）改过时必须看得见：
        // 看不见的自定义地址是查不出来的故障——而它还会让云端识别整条实时链路失效
        // （实时地址是写死的官方域名，见 CloudASRSettings.openAIUsesOfficialEndpoint）。
        // 地址**从 @AppStorage 的值读**而不是读 Settings.currentBaseURL：后者不是 @Published，
        // 点了「恢复官方地址」界面不会重算
        if baseURL != LLMProvider.openai.defaultBaseURL {
            BoundaryRow(text: SettingsCopy.endpointOverridden + baseURL) {
                Button(tr("恢复官方地址", "Restore the official URL")) {
                    baseURL = LLMProvider.openai.defaultBaseURL
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func refreshKeyTail() {
        keyTail = SettingsStatusCard.keyTail(KeychainHelper.loadAPIKey(account: LLMProvider.openai.keychainAccount))
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

    // MARK: 脚注：五个入口，一颗按钮都没有

    /// 设计稿 Settings-Status 的那一行：关于 · 隐私 · 检查更新 · 重看引导 · 历史记录。
    /// 「专有词汇表」与「语言」5.3.0 从这里搬进上面那张卡（写作偏好 / 界面语言两行）：
    /// 它们是"我的设置"，不是"关于这个 App"。
    ///   • 「重看引导」住在这里（用户 2026-09-20 拍板）：那份引导讲的是整个产品怎么用，不是一条设置；
    ///   • 「历史记录」直接打开 Transcripts 目录（5.0.2 起没有历史窗口）。
    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            footerLink(tr("关于", "About")) {
                SettingsNavigator.shared.go(to: .about)
            }
            dot
            footerLink(tr("隐私", "Privacy")) {
                SettingsNavigator.shared.go(to: .about, intent: .privacy)
            }
            dot
            footerLink(tr("检查更新", "Check for Updates")) {
                SettingsNavigator.shared.go(to: .about, intent: .checkUpdate)
            }
            dot
            footerLink(tr("重看引导", "Review the guide")) {
                OnboardingWindowController.shared.show()
            }
            dot
            footerLink(tr("历史记录", "History")) {
                // 5.0.5 起听写记录是 Logs/MicType/Transcripts 里按天的纯文本，
                // 这颗按钮直接打开那个目录。目录还没建就先建再开，免得点了什么都不发生
                let dir = HistoryStore.shared.directory
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                Log.info("Open transcripts folder from settings footer")
                NSWorkspace.shared.open(dir)
            }
            Spacer()
        }
        .font(.system(size: 11))
    }

    private var dot: some View {
        Text("·").foregroundColor(Theme.palette(scheme).muted)
    }

    private func footerLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundColor(Theme.palette(scheme).muted)
            .fixedSize()
    }
}

// MARK: - 顶上那张状态卡

/// 左：连接状态 + Key 尾号；右：本周三格（分钟 / 字数 / 约 $）。设计稿 Settings-Status。
struct SettingsStatusCard: View {
    /// Key 的尾号（nil = 没有 Key → 「未连接」）
    let keyTail: String?
    let week: UsageWeek
    @Environment(\.colorScheme) private var scheme

    /// Key 尾号：末 4 位（纯函数，单测钉住"不够长就不显示"——
    /// 尾号是给人认"是不是那一把"用的，一把 6 位的 Key 露 4 位就等于没藏）
    static func keyTail(_ key: String?) -> String? {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), key.count >= 12 else {
            return nil
        }
        return String(key.suffix(4))
    }

    static func connectionLine(connected: Bool) -> String {
        connected ? tr("OpenAI · 已连接", "OpenAI · Connected")
                  : tr("OpenAI · 未连接", "OpenAI · Not connected")
    }

    var body: some View {
        let palette = Theme.palette(scheme)
        MTCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 40, height: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(keyTail != nil ? Color(hex: 0x30D158) : palette.muted)
                                .frame(width: 7, height: 7)
                            Text(Self.connectionLine(connected: keyTail != nil))
                                .font(.system(size: 14, weight: .semibold))
                        }
                        if let tail = keyTail {
                            Text("Key ···" + tail)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(palette.muted)
                        }
                    }
                    Spacer()
                    Text(tr("本周", "THIS WEEK"))
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundColor(palette.muted)
                }
                Rectangle()
                    .fill(scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06))
                    .frame(height: 1)
                HStack(spacing: 12) {
                    cell(UsageFormat.minutes(week))
                    cell(UsageFormat.chars(week))
                    cell(UsageFormat.cost(week))
                }
            }
        }
    }

    private func cell(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 24, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 「写作偏好」那一行的值（纯函数）

enum WritingPreferencesSummary {
    /// 词汇表几条：与热词解析同一套分隔符（Settings.listSeparators），
    /// 「杰文|捷纹=捷文」算一条（它是一个名字的几种听错法）
    static func vocabularyCount(_ text: String) -> Int {
        Settings.parseList(text).count
    }

    /// 规则几条：按换行与分号、句号切（「署名用 Gen；邮件偏正式。」是两条）。
    /// 全角分号与句号写成 \u{…}：它们是切分规则，不是界面文案（CJKUIStringGuardTests 扫的是字面量）
    static func ruleCount(_ text: String) -> Int {
        text.components(separatedBy: CharacterSet(charactersIn: "\n\r\u{FF1B};\u{3002}"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    static func line(vocabulary: String, rules: String) -> String {
        let terms = vocabularyCount(vocabulary)
        let count = ruleCount(rules)
        // 英文要分单复数：「1 rules」在一张写着"高级"的卡片上是最扎眼的那种错
        let termWord = terms == 1 ? "term" : "terms"
        let ruleWord = count == 1 ? "rule" : "rules"
        return tr("词汇表 \(terms) 条 · 规则 \(count) 条", "\(terms) \(termWord) · \(count) \(ruleWord)")
    }
}

// MARK: - 专有词汇表（从设置底部那排小字点开）

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
                    // 开头那句解释 5.0.2 删掉：它和词汇表那颗 ⓘ 说的是同一件事，
                    // 只是把两个框往下推了一行

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
            // 「打开日志文件夹」5.0.2 删掉：设置底栏那条「历史记录」打开的就是同一个文件夹，
            // 同一件事不做两个入口
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
            // 「存哪儿、多少条、不上传」5.0.2 不在这三句里了：它是这个开关自己的事，
            // 就写在开关那颗 ⓘ 里（SettingsCopy.behaviourInfo）
            SettingsToggleRow(label: tr("保存听写历史（仅本机）", "Keep transcript history (on this Mac)"),
                              isOn: $keepHistory, info: SettingsCopy.behaviourInfo)
                .font(.callout)
                .foregroundColor(.primary)
            // 5.0.2 砍到一句：要说清的只有"贴出去安不安全"，而那取决于里面**没有**什么
            Text(tr("「复制诊断信息」里不含 API Key，也不含任何听写内容，可以放心贴给别人。",
                    "“Copy diagnostics” contains no API key and no transcribed text, so it is safe to paste to someone."))
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
