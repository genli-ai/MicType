import SwiftUI
import AppKit
import Combine

// MARK: - 历史记录窗口

/// 历史窗口的宿主控制器（与 SettingsWindowController 同构：单例 + 懒建窗口 + 语言跟随）。
///
/// 为什么要单独记住"打开窗口前的前台 App"：点"插入到当前光标"时前台已经是 MicType 自己，
/// 这时候读 frontmostApplication 只会读到我们自己。必须在窗口抢焦点之前把目标快照下来，
/// 这和录音起点快照 targetBundleID 是同一个道理。
final class HistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = HistoryWindowController()
    private var window: NSWindow?
    private var langObserver: AnyCancellable?
    private var escMonitor: Any?

    /// 打开窗口前的前台 App，"插入到当前光标"就送回它
    private(set) var previousAppBundleID = ""

    func show() {
        // 先快照目标，再激活自己——顺序颠倒就永远只能拿到 MicType 自己
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if !front.isEmpty && front != Bundle.main.bundleIdentifier {
            previousAppBundleID = front
        }

        if window == nil {
            let hosting = NSHostingController(rootView: HistoryView())
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 640, height: 540))
            w.minSize = NSSize(width: 520, height: 360)
            w.center()
            w.delegate = self
            window = w
            langObserver = L10n.shared.$language.sink { [weak self] lang in
                self?.window?.title = lang == .zh ? "MicType 历史记录" : "MicType History"
            }
        }
        window?.title = tr("MicType 历史记录", "MicType History")
        installEscMonitor()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Esc 关闭

    /// 用本地事件监视器而不是 cancelOperation：搜索框拿到焦点时 Esc 会被 NSTextField 自己吃掉，
    /// 走响应链就传不到窗口了。监视器只认本窗口的 Esc，不影响其它地方。
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let window = self.window else { return event }
            if event.keyCode == 53, event.window === window {   // 53 = Esc
                window.close()
                return nil
            }
            return event
        }
    }

    private func removeEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeEscMonitor()
    }

    // MARK: 重新插入

    /// 把历史文本重新插入到打开窗口前那个 App 的光标处。
    /// 流程：收起窗口 → 让出前台 → TextInserter 自己把目标拉回前台并确认到位后粘贴。
    /// 用 conservative 时序：焦点刚被我们抢走又还回去，输入框需要一点时间重新吃键。
    func insertIntoPreviousApp(_ text: String, completion: @escaping (Bool) -> Void) {
        let target = previousAppBundleID
        guard !target.isEmpty else {
            Log.warn("History insert: no previous app recorded")
            completion(false)
            return
        }
        window?.orderOut(nil)
        NSApp.deactivate()
        Log.info("History insert target=\(target) chars=\(text.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            TextInserter.insert(text, targetBundleID: target,
                                allowClipboardRestore: true,
                                conservativePaste: true) { outcome in
                Log.info("History insert outcome=\(outcome == .pasted ? "pasted" : "clipboardOnly")")
                completion(outcome == .pasted)
            }
        }
    }
}

// MARK: - 词汇表追加

enum VocabularyEditor {
    /// 把一条词条追加进设置里的词汇表。right 为空 = 只当热词；否则写成「错写=正写」硬替换。
    /// 已存在的词条不重复追加（大小写敏感比较——西文大小写不同的写法用户可能是故意的）。
    @discardableResult
    static func append(wrong: String, right: String) -> Bool {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return false }
        let entry = r.isEmpty ? w : "\(w)=\(r)"

        let current = Settings.shared.customVocabulary
        let existing = current
            .components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if existing.contains(entry) { return false }

        var updated = current
        if !updated.isEmpty && !updated.hasSuffix("\n") {
            updated += "\n"
        }
        Settings.shared.customVocabulary = updated + entry
        Log.info("Vocabulary entry added from history")
        return true
    }
}

// MARK: - 界面

struct HistoryView: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var store = HistoryStore.shared

    @State private var query = ""
    @State private var expanded: Set<UUID> = []
    @State private var status = ""
    @State private var statusToken = 0

    @State private var showVocabSheet = false
    @State private var vocabWrong = ""
    @State private var vocabRight = ""

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var filtered: [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.items }
        return store.items.filter {
            $0.polished.localizedCaseInsensitiveContains(q) || $0.raw.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filtered) { item in
                        row(item)
                            .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 360)
        .sheet(isPresented: $showVocabSheet) { vocabSheet }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField(tr("搜索识别原文与最终文本…", "Search raw and final text…"), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(tr("清除搜索", "Clear search"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(store.items.isEmpty
                 ? tr("暂无记录", "No transcripts yet")
                 : tr("没有匹配的记录", "No matching transcripts"))
                .foregroundColor(.secondary)
            if store.items.isEmpty {
                Text(tr("轻点热键听写一次，这里就会出现记录。", "Tap the hotkey to dictate once and it will show up here."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(status.isEmpty
                 ? tr("共 \(store.items.count) 条 · 最多保留 200 条", "\(store.items.count) items · keeps the latest 200")
                 : status)
                .font(.caption)
                .foregroundColor(status.isEmpty ? .secondary : .primary)
            Spacer()
            Text(tr("按 ⎋ 关闭", "Press ⎋ to close"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 单行

    @ViewBuilder
    private func row(_ item: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.stamp.string(from: item.date))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                actions(item)
            }
            Text(item.polished)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if item.rawDiffers {
                Button {
                    if expanded.contains(item.id) {
                        expanded.remove(item.id)
                    } else {
                        expanded.insert(item.id)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: expanded.contains(item.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                        Text(tr("识别原文", "Raw transcript"))
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                if expanded.contains(item.id) {
                    Text(item.raw)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.12))
                        .cornerRadius(4)
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ item: HistoryItem) -> some View {
        HStack(spacing: 6) {
            Button(tr("复制", "Copy")) {
                copy(item.polished)
            }
            Button(tr("插入到当前光标", "Insert at cursor")) {
                insert(item.polished)
            }
            Button(tr("加入词汇表", "Add to vocabulary")) {
                // 听错的写法藏在识别原文里，所以优先拿 raw 预填，让用户删剩那个词
                vocabWrong = (item.rawDiffers ? item.raw : item.polished)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                vocabRight = ""
                showVocabSheet = true
            }
        }
        .font(.caption)
        .controlSize(.small)
    }

    // MARK: 加入词汇表的小面板

    private var vocabSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("加入词汇表", "Add to vocabulary"))
                .font(.headline)
            Text(tr("把听错的写法删剩那一个词，再填上正确写法，以后一律自动改正；正确写法留空则只作为热词送进识别模型。",
                    "Trim the misheard text down to the single word, then type the correct form — it will be rewritten automatically from now on. Leave the correct form empty to add it as a hotword only."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(tr("听错的写法", "Misheard form"), text: $vocabWrong)
                .textFieldStyle(.roundedBorder)
            TextField(tr("正确写法（可留空）", "Correct form (optional)"), text: $vocabRight)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button(tr("取消", "Cancel")) { showVocabSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button(tr("加入", "Add")) {
                    let added = VocabularyEditor.append(wrong: vocabWrong, right: vocabRight)
                    showVocabSheet = false
                    flash(added ? tr("已加入词汇表", "Added to vocabulary")
                                : tr("词汇表里已有这一条", "Already in the vocabulary"))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vocabWrong.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: 动作

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        flash(tr("已复制", "Copied"))
    }

    private func insert(_ text: String) {
        HistoryWindowController.shared.insertIntoPreviousApp(text) { pasted in
            if pasted {
                Sounds.playSuccess()
            } else {
                // 没插进去也不能让文字消失：留在剪贴板里，用户自己 ⌘V
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                Sounds.playError()
            }
        }
    }

    /// 底部状态条：2 秒后自己消失。token 保证连点时只有最后一次负责清空。
    private func flash(_ message: String) {
        status = message
        statusToken += 1
        let token = statusToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if token == statusToken { status = "" }
        }
    }
}
