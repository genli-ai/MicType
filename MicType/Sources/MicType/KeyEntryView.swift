import SwiftUI
import AppKit

// MARK: - 粘贴即验证的 Key 输入（设置页「连接」段 / 引导第 5 屏共用）

/// Key 的三态验证。**唯一**往钥匙串写 Key 的地方，而且只在验证通过之后写。
///
/// 为什么单独抽一层：3.3 之前「保存 Key」只管写钥匙串、真验证挂在模型框旁的「测试」按钮上，
/// 于是可以存一把废 Key 还看到绿对勾，真正出事要等到下一次按住说话。竞品（Raycast / BoltAI）
/// 都是粘贴 → 当场验证 → 通过才存，这一层就是那套流程。
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
    /// 验证代数：切服务商 / 又改了一次 Key 时，旧请求回来不许覆盖新状态
    private var generation = 0

    var isVerifying: Bool { status == .verifying }

    /// 切服务商时调用：上一档的结论对这一档毫无意义
    func reset(loadedKey: String?) {
        generation += 1
        verifiedKey = loadedKey
        status = .idle
    }

    /// 用户又动了输入框：把上一次的结论撤掉，别让旧的 ✓ 挂在一把新 Key 旁边
    func invalidate() {
        guard status != .idle else { return }
        generation += 1
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
    /// 顺带把区域、WorkspaceId、模型有没有在控制台开通一起验了（LLM 的 /models 探针验不到这些）。
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
        generation += 1
        let gen = generation

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
        let hadPrevious = KeychainHelper.loadAPIKey(account: provider.keychainAccount) != nil
        /// 两条探针回来之后做的事一模一样：过了就写钥匙串，没过就一个字节都不动
        let settle: (Bool, String, String, String) -> Void = { [weak self] ok, label, model, message in
            guard let self = self, self.generation == gen else { return }
            if ok {
                KeychainHelper.saveAPIKey(trimmed, account: provider.keychainAccount)
                self.verifiedKey = trimmed
                self.status = .connected(provider: label, model: model)
                Log.info("API key verified provider=\(provider.rawValue) model=\(model)")
            } else {
                // 失败不动钥匙串：原来那把要是好的，不该被一次手滑的粘贴连累
                self.status = .failed(reason: message, keptPrevious: hadPrevious)
                Log.warn("API key verification failed provider=\(provider.rawValue) model=\(model)")
            }
        }

        switch probe {
        case .llm:
            // 走 testModel = 走与真实润色完全相同的那条路（含 Responses / chat 的分叉）
            LLMClient.testModel(model, provider: provider, candidateKey: trimmed) { ok, message in
                settle(ok, provider.segmentName, model, message)
            }
        case .cloudASR(let cloudProvider):
            // 识别页：直接打识别端点。配不出配置（区域没接入点）就当面说，别偷偷换一个区域去验
            guard var config = CloudASRSettings.currentConfig(), config.provider == cloudProvider else {
                status = .failed(reason: tr("云端识别在当前接入区域没有接入点，请先改区域",
                                            "Cloud recognition has no endpoint in the selected region - change the region first"),
                                 keptPrevious: hadPrevious)
                return
            }
            config.apiKey = trimmed
            let modelName = cloudProvider == .alibaba
                ? Settings.shared.cloudAlibabaModel.rawValue
                : OpenAITranscribeClient.defaultModel
            CloudASRProbe.run(config: config) { result in
                switch result {
                case .success:
                    settle(true, cloudProvider.displayName, modelName, "")
                case .failure(let failure):
                    settle(false, cloudProvider.displayName, modelName, failure.message)
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
    /// Key 存储与费用那两句要不要跟在输入框下面。引导第 5 屏把它们钉在整屏底部
    /// （那是"固定的成本声明"该在的位置），所以那一处传 false——**文字仍是同两个常量**，
    /// 只是摆的地方不同（同一个事实只写一处，见 C10）。
    var showsStorageNotes: Bool = true
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
                if showsStorageNotes {
                    Text(LLMCatalog.keyStorageNote + " " + LLMCatalog.billingNote)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if LLMCatalog.apiKeyConsoleURL(for: provider) == nil {
                    Text(tr("在这家服务商自己的控制台里创建 Key。", "Create the key in this provider's own console."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(LLMCatalog.newAccountNote)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                // 本机模型：没有 Key 不是"还没配好"，是这一档的正常状态
                Text(tr("本机模型不需要 API Key（Ollama 忽略它，LM Studio 压根不要）。模型在你自己的机器上跑，文字不出网、不花钱。",
                        "Local models need no API key (Ollama ignores it, LM Studio does not ask for one). The model runs on your own Mac, so nothing leaves it and nothing is billed."))
                    .font(.caption)
                    .foregroundColor(.secondary)
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
        verifier.reset(loadedKey: stored)
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
