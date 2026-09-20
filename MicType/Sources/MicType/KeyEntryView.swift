import SwiftUI
import AppKit

// MARK: - 粘贴即验证的 Key 输入（设置页「连接」段 / 引导第 5 屏共用）

/// Key 的三态验证。**唯一**往钥匙串写 Key 的地方，而且只在验证通过之后写。
///
/// 为什么单独抽一层：3.3 之前「保存 Key」只管写钥匙串、真验证挂在模型框旁的「测试」按钮上，
/// 于是可以存一把废 Key 还看到绿对勾，真正出事要等到下一次按住说话。竞品（Raycast / BoltAI）
/// 都是粘贴 → 当场验证 → 通过才存，这一层就是那套流程。
/// 验证代数的**长寿命**账本：谁的结论还算数，由它说了算。
///
/// 为什么代数不能只住在 KeyVerifier 里：设置页的路由用 `.id(nav.route)` 重建页面
/// （见 SettingsView.page），粘完 Key 立刻按 Esc / 点「‹ 设置」，KeyEntryView 连同它的
/// @StateObject 一起被释放，而那趟验证还在路上（从 UAE 出海要 1–5 秒）。代数记在视图里，
/// 回调回来就没人可问：验证通过的那把 Key 不落盘、日志里也没有一行，用户在概览上读到的是
/// 「还没填 Key」，以为自己没粘上。所以**落盘与日志只认这个账本**（它比任何视图都活得久），
/// 屏幕上那一行才认视图还在不在。
final class KeyVerificationLedger {
    static let shared = KeyVerificationLedger()

    /// 回调不保证回到主线程（云端识别那两条探针就不是），所以这张表自己上锁
    private let lock = NSLock()
    /// 钥匙串账户 → 最新一次验证的代数
    private var generations: [String: Int] = [:]

    private init() {}

    /// 领一个新代数。每一次 verify / reset / invalidate 都要领——领完，之前那些就不算数了
    @discardableResult
    func nextGeneration(for account: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (generations[account] ?? 0) + 1
        generations[account] = next
        return next
    }

    /// 这一代还是这一档最新的那一代吗。不是 = 用户后来又动过输入框，这趟的结果一律作废
    func isCurrent(_ generation: Int, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[account] == generation
    }
}

final class KeyVerifier: ObservableObject {

    enum Status: Equatable {
        case idle
        case verifying
        /// 通过：报出「跟谁通了、用的哪个型号」——只说"成功"的提示等于没说
        case connected(provider: String, model: String)
        /// 不通过：原因 + 下一步。keptPrevious = 钥匙串里原来那把仍然有效，本次没动它
        case failed(reason: String, keptPrevious: Bool)
        /// 用户把输入框清空了：这是"删掉 Key"的明确动作
        case cleared
    }

    @Published private(set) var status: Status = .idle
    /// 已经验证通过、正躺在钥匙串里的那把（用来判"要不要重验"，只在内存里比对，不外泄）
    private var verifiedKey: String?
    /// 两本代数，管的是两件事：
    ///   • **这一页的**代数（下面这个）决定"屏幕上那一行还要不要改"——切服务商、重新载入
    ///     之后，上一档的回答不许改写现在这一档的状态行；
    ///   • **落盘与日志**的代数在 KeyVerificationLedger 里（见那边的注释）：它比视图活得久，
    ///     所以粘完就离开这一页，验证通过的 Key 照样进钥匙串。
    private var viewGeneration = 0
    /// 这一层现在为哪一档服务。invalidate() 手上没有 provider，只能靠它去账本上销号
    private var account: String?
    private let ledger = KeyVerificationLedger.shared

    var isVerifying: Bool { status == .verifying }

    /// 切服务商时调用：上一档的结论对这一档毫无意义
    /// 只翻**这一页的**代数，不动账本：重新载入不是"用户改主意了"。
    /// 账本一翻，粘完立刻离开又马上回来的那趟验证就会连钥匙串都写不进去——那正是要修的那个 bug。
    func reset(loadedKey: String?, provider: LLMProvider) {
        account = provider.keychainAccount
        viewGeneration += 1
        verifiedKey = loadedKey
        status = .idle
    }

    /// 用户又动了输入框：把上一次的结论撤掉，别让旧的 ✓ 挂在一把新 Key 旁边
    func invalidate() {
        guard status != .idle else { return }
        // 这一次要连账本一起销号：用户又动了输入框，在路上那一把已经不是他要的那一把，
        // 它回来时连钥匙串都不许写
        viewGeneration += 1
        if let account = account { ledger.nextGeneration(for: account) }
        status = .idle
    }

    /// 这把 Key 需要验证吗（空、或与已验证的那把一字不差就不必再跑一趟）
    func needsVerification(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed != verifiedKey
    }

    /// 这把 Key 用哪条链路去验。
    ///
    /// 为什么必须可插拔：识别页上的 Key 属于 Qwen/OpenAI 的**云端识别**，用户的润色服务商
    /// 完全可能是另一家——照搬 LLM 探针就等于把阿里云的 Key 发到 OpenAI 去。
    /// （`.llm` 这条路本身也曾有同一个毛病：dispatch 读全局当前档，于是引导页刚选中
    /// 但还没生效的那一档会被发到上一档的端点上。现在 provider 一路显式传到 dispatch，
    /// 验证打的永远是 KeyEntryView 手上这一档。）
    /// 所以识别页走 `.cloudASR`：直接打识别端点，发 1 秒合成音，
    /// 顺带把接入地址、模型有没有在控制台开通一起验了（LLM 的 /models 探针验不到后者）。
    enum Probe: Equatable {
        /// 走润色/指令那条链路（AI 页默认）
        case llm
        /// 走云端识别端点，1 秒合成音（识别页）
        case cloudASR(CloudASRProvider)
    }

    /// 发一次真请求验证这把 Key。通过才写钥匙串；不通过**一个字节都不写**。
    /// - model: 拿来探活的型号（用润色型号：它是每句话都要跑的那个）
    /// - probe: 走哪条链路，见 Probe
    func verify(key: String, provider: LLMProvider, model: String, probe: Probe = .llm) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = provider.keychainAccount
        let ledger = self.ledger
        self.account = account
        viewGeneration += 1
        let viewGen = viewGeneration
        let gen = ledger.nextGeneration(for: account)

        guard !trimmed.isEmpty else {
            // 清空 + 失焦 = 明确要删掉这把 Key。钥匙串里没有就只是回到初始态。
            let had = KeychainHelper.loadAPIKey(account: provider.keychainAccount) != nil
            if had {
                KeychainHelper.deleteAPIKey(account: provider.keychainAccount)
                Log.info("API key cleared provider=\(provider.rawValue)")
            }
            verifiedKey = nil
            status = had ? .cleared : .idle
            return
        }

        status = .verifying
        // 这把 Key 里带着 WorkspaceId 的话，趁这一刻落盘：润色那条路不读钥匙串，
        // 只能从设置里拿它——两边拼出来的候选主机必须是同一张表（见 rememberWorkspace）
        if provider == .qwen { CloudASRSettings.rememberWorkspace(fromKey: trimmed) }
        let hadPrevious = KeychainHelper.loadAPIKey(account: provider.keychainAccount) != nil
        /// 两条探针回来之后做的事一模一样：过了就写钥匙串，没过就一个字节都不动
        let settle: (Bool, String, String, String) -> Void = { [weak self] ok, label, model, message in
            // 先问账本、后问视图：粘完就按 Esc 回概览的人，这会儿 self 已经没了，
            // 但他粘的那把 Key 验证通过就必须落盘、必须留下一行日志——4.0.2 这两件事
            // 都挂在 `guard let self` 后面，于是一次成功的验证什么痕迹都不留
            guard ledger.isCurrent(gen, for: account) else {
                // 作废也要记一行：否则"我明明粘了"这类反馈在日志里彻底没有对应
                Log.info("API key verification discarded provider=\(provider.rawValue) reason=superseded")
                return
            }
            if ok {
                KeychainHelper.saveAPIKey(trimmed, account: account)
                Log.info("API key verified provider=\(provider.rawValue) model=\(model)")
            } else {
                // 失败不动钥匙串：原来那把要是好的，不该被一次手滑的粘贴连累。
                // 原因也要记：4.0.0 只记了"失败了"，用户看到的那句话（含服务商错误码）
                // 一个字都没落盘，事后完全无从排查。记的是文案，不含 Key。
                Log.warn("API key verification failed provider=\(provider.rawValue) model=\(model) "
                         + "reason=" + String(message.prefix(200)))
            }
            // 屏幕上那一行只有这一页还在、而且还停在这一档时才有人看
            guard let self = self, self.viewGeneration == viewGen else { return }
            if ok {
                self.verifiedKey = trimmed
                self.status = .connected(provider: label, model: model)
            } else {
                self.status = .failed(reason: message, keptPrevious: hadPrevious)
            }
        }

        switch probe {
        case .llm:
            // Qwen 这一档的接入地址是试出来的：先用最便宜的那趟（GET /models）把主机定下来，
            // 再照常走 testModel。定不下来就直接报那一趟的原因——它比"型号不对"准得多。
            //
            // **每换一把 Key 都要重新试一遍**：缓存的那台是"上一把 Key 的答案"，换了账号
            // （国际站 → 北京工作空间）之后拿它去打只会得到一个 401，而那句话指向的是 Key，
            // 用户翻不到头上。缓存的主机仍排在候选表第一位，所以没换端点时这一趟只多一个请求。
            // 粘过接入地址的人例外：他已经把答案给了，不该再拿他的 Key 去试别的主机。
            guard provider == .qwen,
                  AlibabaEndpoint.normalizeHost(Settings.shared.qwenAPIHost) == nil else {
                LLMClient.testModel(model, provider: provider, candidateKey: trimmed) { ok, message in
                    settle(ok, provider.segmentName, model, message)
                }
                return
            }
            AlibabaHostResolver.resolve(
                apiKey: trimmed,
                candidates: CloudASRSettings.currentHostCandidates(apiKey: trimmed)) { result in
                switch result {
                case .failure(let failure):
                    settle(false, provider.segmentName, model, failure.message)
                case .success(let host):
                    // 和 settle 同一道闸（问的也是账本，不是视图）：这几秒里用户可能又粘了
                    // 一把别的 Key，让上一把的答案把接入地址写掉，下一把就被钉在一台不属于它的主机上
                    if ledger.isCurrent(gen, for: account) {
                        CloudASRSettings.rememberResolution(host: host, model: nil)
                    }
                    LLMClient.testModel(model, provider: provider, candidateKey: trimmed) { ok, message in
                        settle(ok, provider.segmentName, model, message)
                    }
                }
            }
        case .cloudASR(let cloudProvider):
            // 识别页：直接打识别端点，1 秒合成音。阿里云那一档还要先把接入主机试出来、
            // 模型 404 时自动换 qwen3-asr-flash（见 CloudASRSetup）。
            guard var config = CloudASRSettings.currentConfig(), config.provider == cloudProvider else {
                // 走到这里只可能是识别引擎在这半秒里被改回了本地档。
                // 这一支不经过 settle，所以日志要自己记：用户看得见的每一句失败都要落盘，
                // 否则他抄着这句话来问，日志里一个字都找不到（4.0.1 立的规矩）。
                Log.warn("API key verification skipped provider=\(provider.rawValue) "
                         + "reason=cloud recognition not on this provider")
                status = .failed(reason: tr("云端识别没有开在这一档上，请先在 设置 → 云端 AI 里打开",
                                            "Cloud recognition is not set to this provider — turn it on first under Settings → Cloud AI"),
                                 keptPrevious: hadPrevious)
                return
            }
            config.apiKey = trimmed
            guard cloudProvider == .alibaba else {
                CloudASRProbe.run(config: config) { result in
                    switch result {
                    case .success:
                        settle(true, cloudProvider.displayName, OpenAITranscribeClient.defaultModel, "")
                    case .failure(let failure):
                        settle(false, cloudProvider.displayName,
                               OpenAITranscribeClient.defaultModel, failure.message)
                    }
                }
                return
            }
            CloudASRSetup.verifyAlibaba(apiKey: trimmed, config: config,
                                        candidates: CloudASRSettings.currentHostCandidates(apiKey: trimmed)) { result in
                switch result {
                case .success(let success):
                    // 同一道代数闸：放弃掉的那一次验证不许改写接入地址与识别模型
                    if ledger.isCurrent(gen, for: account) {
                        CloudASRSettings.rememberResolution(host: success.host, model: success.model)
                    }
                    settle(true, cloudProvider.displayName, success.model.rawValue, "")
                case .failure(let failure):
                    settle(false, cloudProvider.displayName,
                           Settings.shared.cloudAlibabaModel.rawValue, failure.message)
                }
            }
        }
    }

    /// 状态 → 屏幕上那一行（纯函数，单测钉住三态的措辞）。nil = 这一行不显示。
    static func statusText(_ status: Status) -> String? {
        switch status {
        case .idle:
            return nil
        case .verifying:
            return tr("正在验证…", "Checking…")
        case .connected(let provider, let model):
            return tr("已连通 ✓ ", "Connected ✓ ") + provider + " · " + model
        case .failed(let reason, let keptPrevious):
            let base = tr("连不上：", "Could not connect: ") + reason
            guard keptPrevious else { return base }
            return base + tr("（上一把已验证过的 Key 仍在用，没有被覆盖）",
                             " (your previously verified key is still in use and was not overwritten)")
        case .cleared:
            return tr("已清空：这个服务商的 Key 已从钥匙串删除。",
                      "Cleared: this provider's key was removed from the Keychain.")
        }
    }

    /// 状态行的颜色（绿=通、橙=不通、灰=其余）
    static func statusColor(_ status: Status) -> Color {
        switch status {
        case .connected: return .green
        case .failed: return .orange
        case .idle, .verifying, .cleared: return .secondary
        }
    }
}

/// 一个 SecureField + 一行状态 + 「去申请 Key ↗」+ 固定的存储/费用说明。
/// 设置页「连接」段和引导第 5 屏共用这一个控件——两处的说法必须逐字一致（见 C10）。
struct KeyEntryView: View {
    let provider: LLMProvider
    /// 拿来探活的型号（润色型号）
    let model: String
    /// 用哪条链路验这把 Key。默认走 LLM（AI 页）；识别页传 `.cloudASR(...)`，
    /// 直接打识别端点、发 1 秒合成音（理由见 KeyVerifier.Probe）
    var probe: KeyVerifier.Probe = .llm
    /// 验证结束时通知外面（true = 通过）。菜单栏的「配置 AI…」之类要据此刷新。
    var onStatusChange: ((KeyVerifier.Status) -> Void)? = nil

    @ObservedObject private var l10n = L10n.shared
    @StateObject private var verifier = KeyVerifier()
    @State private var key = ""
    /// 输入框里这串字是**为哪一档**读进来/敲进来的。切服务商的那一刹那，失焦事件可能先于
    /// 重新载入到达——没有这道闸，A 档输入框里的 Key 会被当成 B 档的 Key 去验证甚至存起来。
    @State private var loadedProvider: LLMProvider?
    @FocusState private var focused: Bool

    /// 一次变化里多出这么多字符就当是粘贴：手打 Key 不会一次跳这么多，
    /// 而粘贴正是 99% 的真实输入方式——等他失焦再验证会让人以为这一步没反应。
    private static let pasteJump = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if provider.requiresAPIKey {
                HStack(spacing: 8) {
                    SecureField(tr("粘贴 \(provider.segmentName) 的 API Key", "Paste your \(provider.segmentName) API key"),
                                text: $key)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { verifyNow() }
                    if let url = LLMCatalog.apiKeyConsoleURL(for: provider) {
                        Button(tr("去申请 Key ↗", "Get a key ↗")) {
                            guard let link = URL(string: url) else { return }
                            NSWorkspace.shared.open(link)
                        }
                        .fixedSize()
                    }
                }
                if let text = KeyVerifier.statusText(verifier.status) {
                    Text(text)
                        .font(.caption)
                        .foregroundColor(KeyVerifier.statusColor(verifier.status))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                // 输入框下面永远留这一行**价格**（LLMCatalog.billingNote，全 App 唯一出处）：
                // Key 怎么存、新账号要先充值这些细则收进段头那颗 ⓘ（SettingsCopy.keyInfo），
                // 控件旁边只留代价——代价不是解释，永远不进 ⓘ
                Caption(LLMCatalog.billingNote)
            } else {
                // 本机模型：没有 Key 不是"还没配好"，是这一档的正常状态
                Caption(SettingsCopy.localModelNeedsNoKey)
            }
        }
        .onAppear { load() }
        .onChange(of: provider) { _, _ in load() }
        .onChange(of: key) { oldValue, newValue in
            // 粘贴（一次跳一大截）当场验证；手改则先把旧结论撤掉，等失焦/回车再验
            if newValue.count - oldValue.count >= KeyEntryView.pasteJump {
                verifyNow()
            } else {
                verifier.invalidate()
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { verifyNow() }
        }
        .onChange(of: verifier.status) { _, newValue in
            onStatusChange?(newValue)
        }
        // 状态行是一次性快照，切语言要跟着换（见 CLAUDE.md「i18n 快照字符串」）
        .onChange(of: l10n.language) { _, _ in verifier.invalidate() }
    }

    private func load() {
        let stored = KeychainHelper.loadAPIKey(account: provider.keychainAccount)
        // 先告诉 verifier 这把 Key 已经是验证过的，再写输入框：反过来的话
        // onChange(of: key) 会把"载入"当成一次粘贴，白跑一趟网络
        verifier.reset(loadedKey: stored, provider: provider)
        loadedProvider = provider
        key = stored ?? ""
    }

    /// 验证入口：空框（且钥匙串里有东西）= 要删；没变过的 Key 不重复跑一趟网络
    private func verifyNow() {
        guard provider.requiresAPIKey, loadedProvider == provider else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // 从来没填过就别在屏幕上留一行「已清空」
            guard KeychainHelper.loadAPIKey(account: provider.keychainAccount) != nil else { return }
            verifier.verify(key: "", provider: provider, model: model, probe: probe)
            return
        }
        guard verifier.needsVerification(trimmed), !verifier.isVerifying else { return }
        verifier.verify(key: trimmed, provider: provider, model: model, probe: probe)
    }
}

// MARK: - 阿里云的「接入地址（可选）」

/// 设置页与引导页共用的那个可选输入框（含说明与格式校验）。
///
/// 为什么非共用不可：4.0.1 里这是两份手抄本，引导那一份漏了格式校验，说明文字也另写了一版
/// ——于是在引导里把「接入地址：xxx」连中文标签一起粘进去的人，什么提示都得不到，
/// 那串被 normalizeHost 静默丢弃（等于没填）。同一个事实只写一处（见 keyStorageNote 的做法）。
///
/// 写成 @ViewBuilder 静态函数而不是 View：调用处在 Form / VStack 里，这三样要各占一行，
/// 包成一个 View 会被挤成一行。
/// 「已试通的那台 + 重新探测」只在设置页出现：首配的人手上还没有"上一次"。
enum QwenHostField {

    /// 这串填得像不像一个主机名。空着是常态（交给自动探测），不算错。
    static func isMalformed(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && AlibabaEndpoint.normalizeHost(raw) == nil
    }

    @ViewBuilder
    static func field(host: Binding<String>) -> some View {
        TextField(tr("接入地址（可选）", "API host (optional)"), text: host)
            .textFieldStyle(.roundedBorder)
        // 空着是常态（交给自动探测），所以这里只留一行；"去哪儿复制这一串"收进段头那颗 ⓘ
        Caption(SettingsCopy.hostAutoDetected)
        if isMalformed(host.wrappedValue) {
            Caption(SettingsCopy.hostMalformed, warning: true)
        }
    }
}
