import Foundation

// MARK: - 远端模型目录（model-catalog.json）
//
// 为什么要有这个文件：识别模型是这个产品唯一会「过期」的零件——换代的 ASR 模型随时可能出现，
// 而用户不该为了换模型去等一版 App。所以模型清单从代码里搬到仓库根的 model-catalog.json：
// 发新模型 = 改一个 JSON + push，老版本 App 当天就能看见并一键装上。
//
// 三条纪律：
// 1. **永不自动换模型**。目录只负责「告诉用户有更好的」，换不换、什么时候下载 800 MB 由用户点。
// 2. **永不因为读不到目录而退化**：远端 → 本地缓存 → App 内置资源 → 代码里的字面表，
//    四层兜底，最后一层保证断网、被墙、JSON 写坏时模型列表照样是完整可用的。
// 3. **认不出的格式一律当作没有**（schemaVersion 对不上就忽略远端）——未来的字段绝不能让
//    今天这一版把模型列表读成空。

/// 目录里的双语文案。en 侧永远是纯英文（不得含中文字符或全角标点）。
struct LocalizedText: Codable, Equatable {
    let zh: String
    let en: String

    init(zh: String, en: String) {
        self.zh = zh
        self.en = en
    }

    /// 界面语言决定显示哪一侧；缺一侧就用另一侧（宁可显示英文也不显示空白）
    var localized: String {
        if zh.isEmpty { return en }
        if en.isEmpty { return zh }
        return tr(zh, en)
    }
}

/// 目录里的一个识别模型。
///
/// 只有 `repo` 是必需字段：清单是给未来的自己写的，缺字段要能按默认值读下来，
/// 而不是整份目录解析失败（那等于把老版本 App 的模型列表清空）。
struct CatalogModel: Codable, Equatable, Identifiable {
    /// HuggingFace 仓库 ID，同时是本地目录名的来源（QwenModels.localDirectory）
    let repo: String
    let displayName: LocalizedText
    /// 下载体量（字节，含清单里会下载的全部文件）。只用于界面上那句「约 862 MB」，
    /// **不用于校验**——校验以下载时 HF 给的逐文件大小为准。
    let sizeBytes: Int64
    let quant: String
    let languagesNote: LocalizedText
    /// 干净安装 / 一般用户的首选。目录里应当只有一个 recommended。
    let recommended: Bool
    /// 「只在这些语言上更好」的语言代码。用户为某语言选了它之后，
    /// 就不要再拿 recommended 那一档去劝他换回来——那属于替用户做主。
    /// **当前目录里这一项恒为空**：2026-09-19 的实测推翻了「阿语该换 1.7B」这个推断——
    /// 阿英混说的那一档，0.6B 加词汇表热词把 CER 从 12.5% 压到 4.0%，而 1.7B 基本不吃热词
    /// （16.8%）。机制留着给将来真出现「某语言专用档」的时候用，别再凭跑分往里填语言。
    let recommendedFor: [String]
    /// 运行这个模型所需的最低 App 版本。比当前版本高 → 只提示「需要更新 MicType」，绝不假装能装。
    /// **必须是真的跑不了才往上填**：这个字段填高于当前 App 版本的值，会让一个此刻明明
    /// 跑得好好的模型在菜单栏和识别页挂出一条无解的「需要更新 MicType」——去查更新还会
    /// 被告知已是最新，用户没有任何出口。目录里这两档从 3.3.0 起就能跑，写的就是 3.3.0。
    let minAppVersion: String
    /// 钉死某个 HF 修订（null = 跟随 main）。预留字段，下载器目前只走 main。
    let revision: String?

    var id: String { repo }

    init(repo: String,
         displayName: LocalizedText,
         sizeBytes: Int64,
         quant: String,
         languagesNote: LocalizedText,
         recommended: Bool,
         recommendedFor: [String] = [],
         minAppVersion: String = "",
         revision: String? = nil) {
        self.repo = repo
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.quant = quant
        self.languagesNote = languagesNote
        self.recommended = recommended
        self.recommendedFor = recommendedFor
        self.minAppVersion = minAppVersion
        self.revision = revision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = (try c.decodeIfPresent(String.self, forKey: .repo) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = try c.decodeIfPresent(LocalizedText.self, forKey: .displayName)
            ?? LocalizedText(zh: repo, en: repo)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        quant = try c.decodeIfPresent(String.self, forKey: .quant) ?? ""
        languagesNote = try c.decodeIfPresent(LocalizedText.self, forKey: .languagesNote)
            ?? LocalizedText(zh: "", en: "")
        recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        recommendedFor = try c.decodeIfPresent([String].self, forKey: .recommendedFor) ?? []
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion) ?? ""
        revision = try c.decodeIfPresent(String.self, forKey: .revision)
    }

    /// 这一档是否「为某种语言准备的」（recommendedFor 比对大小写不敏感）
    func isRecommended(forLanguage code: String) -> Bool {
        let wanted = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return false }
        return recommendedFor.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted }
    }
}

/// 一份模型目录。
struct ModelCatalog: Codable, Equatable {
    /// 本版 App 能读懂的格式版本。远端给出别的数字 = 未来格式，直接忽略（见 decode）。
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    /// 目录的发布日期（仅供人看 / 日志）
    let updated: String
    let models: [CatalogModel]

    init(schemaVersion: Int = ModelCatalog.supportedSchemaVersion,
         updated: String,
         models: [CatalogModel]) {
        self.schemaVersion = schemaVersion
        self.updated = updated
        self.models = models
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        updated = try c.decodeIfPresent(String.self, forKey: .updated) ?? ""
        // 单条模型写坏不该毁掉整份目录：逐条解，坏的那条丢掉
        let raw = try c.decodeIfPresent([FailableModel].self, forKey: .models) ?? []
        models = raw.compactMap { $0.value }.filter { !$0.repo.isEmpty }
    }

    /// 允许单条失败的包装：JSON 里混进一个坏对象时只丢那一条
    private struct FailableModel: Decodable {
        let value: CatalogModel?
        init(from decoder: Decoder) throws {
            value = try? CatalogModel(from: decoder)
        }
    }

    /// 目录里的首选模型（干净安装的默认）。没标 recommended 就退回第一条。
    var recommendedModel: CatalogModel? {
        models.first { $0.recommended } ?? models.first
    }

    func model(repo: String) -> CatalogModel? {
        models.first { $0.repo == repo }
    }

    /// 严格解码：schemaVersion 对不上、或一条模型都没有 → 抛错，调用方保留上一层兜底。
    /// 「宁可用旧目录，也不要用一份读不懂的新目录」。
    static func decode(_ data: Data) throws -> ModelCatalog {
        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
        guard catalog.schemaVersion == supportedSchemaVersion else {
            throw MTError("model-catalog.json schemaVersion=\(catalog.schemaVersion) unsupported")
        }
        guard !catalog.models.isEmpty else {
            throw MTError("model-catalog.json has no usable models")
        }
        return catalog
    }

    /// 代码里的最后一层兜底：与仓库根 model-catalog.json 同源。
    /// 断网 + 没缓存 + App 资源缺失时，模型列表仍然是这两档（用户照样能下载、能换）。
    static let builtIn = ModelCatalog(
        schemaVersion: supportedSchemaVersion,
        updated: "2026-09-19",
        models: [
            CatalogModel(
                repo: "mlx-community/Qwen3-ASR-0.6B-6bit",
                displayName: LocalizedText(zh: "Qwen3-ASR 0.6B 6bit（推荐，快）",
                                           en: "Qwen3-ASR 0.6B 6-bit (recommended, fast)"),
                sizeBytes: 861_775_040,
                quant: "6bit",
                languagesNote: LocalizedText(
                    zh: "30 种语言 + 22 种中文方言；中英文最稳，阿语可用，识别全程在本机。",
                    en: "30 languages + 22 Chinese dialects; strongest on Chinese and English, usable on Arabic, fully on-device."),
                recommended: true,
                recommendedFor: [],
                minAppVersion: "3.3.0",
                revision: nil),
            CatalogModel(
                repo: "mlx-community/Qwen3-ASR-1.7B-4bit",
                displayName: LocalizedText(zh: "Qwen3-ASR 1.7B 4bit（更准、更慢）",
                                           en: "Qwen3-ASR 1.7B 4-bit (more accurate, slower)"),
                sizeBytes: 1_607_630_579,
                quant: "4bit",
                languagesNote: LocalizedText(
                    zh: "参数更大，整体更准，但实测慢约一倍、内存占用也更高；它对词汇表热词的响应不如 0.6B，夹英文专名的口述建议仍用推荐档加词汇表。",
                    en: "A larger model: more accurate overall, but measured about twice as slow and heavier on memory. It responds to vocabulary hotwords less than the 0.6B model, so for speech with embedded English names the recommended model plus a vocabulary is still the better route."),
                recommended: false,
                recommendedFor: [],
                minAppVersion: "3.3.0",
                revision: nil),
        ])
}

// MARK: - 版本比较

/// 版本号比较。App 版本用的是 Info.plist 的 CFBundleShortVersionString（"3.3.0"），
/// 目录里的 minAppVersion 同形。纯函数、可单测——「能不能装这个模型」这种判断不允许猜。
enum AppVersionCompare {

    /// 数字分段比较：a < b → -1，相等 → 0，a > b → 1。
    /// 每段只取前导数字（"4.0.0-beta2" 的 "0-beta2" 当 0），段数不同按 0 补齐。
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = segments(a)
        let pb = segments(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// 当前 App 版本是否够得上 minimum。**空的 / 认不出的 minimum 一律算够**：
    /// 目录里漏写一个字段，不该让一个本来能用的模型变成「需要更新 MicType」。
    static func satisfiesMinimum(appVersion: String, minimum: String) -> Bool {
        let trimmed = minimum.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, segments(trimmed).contains(where: { $0 > 0 }) else { return true }
        return compare(appVersion, trimmed) >= 0
    }

    private static func segments(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            var digits = ""
            for ch in part {
                if ch.isNumber { digits.append(ch) } else { break }
            }
            return Int(digits) ?? 0
        }
    }
}

// MARK: - 目录的取用与缓存

/// 模型目录的来源与缓存。
///
/// 取用顺序：jsDelivr CDN → raw.githubusercontent.com → App 内置资源 → 代码字面表。
/// 为什么 CDN 优先：GitHub 的 raw 与 API 在共享出口 IP 下极易 403 限流（3.2.15 的教训——
/// 更新通道自己被限流 = 所有后续修复都送不到），jsDelivr 无限流且国内可达。
final class ModelCatalogStore: ObservableObject {

    static let shared = ModelCatalogStore()

    /// 远端地址按顺序试。@main 指向仓库默认分支的当前内容。
    static let remoteURLs = [
        "https://cdn.jsdelivr.net/gh/genli-ai/MicType@main/model-catalog.json",
        "https://raw.githubusercontent.com/genli-ai/MicType/main/model-catalog.json",
    ]

    /// 启动时最多多久查一次（秒）。查目录是个小 JSON，但也没有任何理由每次启动都查。
    static let checkInterval: TimeInterval = 24 * 3600

    /// 这一次没取到目录时，隔多久可以再试（秒）。
    /// 为什么不沿用 24 小时：一次失败最常见的原因是"启动的那一刻还没联上网"
    /// （酒店 Wi-Fi 的登录页、刚开机）——把这种失败当成"今天查过了"，等于让用户
    /// 一整天看不到新模型，而他其实全天都在线。
    static let failureBackoff: TimeInterval = 30 * 60

    @Published private(set) var catalog: ModelCatalog
    @Published private(set) var isChecking = false
    /// 目录从哪儿来的（只进日志，不进界面）
    private(set) var sourceLabel: String
    /// 手里这份目录是不是**本次运行真的从远端取回来的**。
    /// 缓存 / 内置资源 / 字面表都算 false：它们可能比远端旧好几代，
    /// 而"目录里没有这个仓库"正是删模型的依据之一（见 ModelUpgrader.runCleanup）。
    private(set) var isFromRemote = false

    private let d = UserDefaults.standard

    /// 缓存文件。static：初始化阶段就要读它，那时 self 还不完整。
    private static var cacheFile: URL {
        Paths.appSupportDir.appendingPathComponent("model-catalog.json")
    }

    private var cacheFile: URL { Self.cacheFile }

    private init() {
        // 缓存 → 内置资源 → 字面表。这一段只读本地文件，不联网，绝不阻塞启动。
        if let data = try? Data(contentsOf: Self.cacheFile),
           let cached = try? ModelCatalog.decode(data) {
            catalog = cached
            sourceLabel = "cache"
        } else if let bundled = Bundle.main.url(forResource: "model-catalog", withExtension: "json"),
                  let data = try? Data(contentsOf: bundled),
                  let decoded = try? ModelCatalog.decode(data) {
            catalog = decoded
            sourceLabel = "bundled"
        } else {
            catalog = ModelCatalog.builtIn
            sourceLabel = "built-in"
        }
    }

    var models: [CatalogModel] { catalog.models }

    /// 距上次**成功**取到目录是否已满 24 小时（上一次失败时还要先过退避窗口）
    var isCheckDue: Bool {
        Self.isDue(now: Date().timeIntervalSince1970,
                   lastSuccess: d.double(forKey: SettingsKeys.modelCatalogLastCheck),
                   retryAfter: d.double(forKey: SettingsKeys.modelCatalogRetryAfter))
    }

    /// 到点了没有。纯函数（时间全由调用方给），可单测——这道节流写错的两个后果都很难看：
    /// 要么每次启动都去打一次网，要么把用户按在一份旧目录上一整天。
    static func isDue(now: TimeInterval,
                      lastSuccess: TimeInterval,
                      retryAfter: TimeInterval,
                      interval: TimeInterval = ModelCatalogStore.checkInterval) -> Bool {
        if retryAfter > 0, now < retryAfter { return false }
        guard lastSuccess > 0 else { return true }
        return now - lastSuccess >= interval
    }

    /// 启动时调用：到点才查。completion 在主线程回调，参数 = 这次是否真的查了远端。
    func checkAtLaunchIfDue(completion: @escaping (Bool) -> Void) {
        guard isCheckDue else {
            Log.info("Model catalog check skipped (not due) source=\(sourceLabel) models=\(models.count)")
            DispatchQueue.main.async { completion(false) }
            return
        }
        refresh { _ in completion(true) }
    }

    /// 拉一次远端目录。completion 在主线程回调（成功与否）。
    /// 失败不动现有目录——读不到新目录，用旧的照样能用。
    func refresh(completion: ((Bool) -> Void)? = nil) {
        guard !isChecking else {
            DispatchQueue.main.async { completion?(false) }
            return
        }
        isChecking = true
        fetch(index: 0) { [weak self] data, source in
            guard let self = self else { return }
            self.isChecking = false
            let now = Date().timeIntervalSince1970
            guard let data = data, let fresh = try? ModelCatalog.decode(data) else {
                // 失败**不打 24 小时的戳**，只记一个短退避：没取到目录不等于今天查过了
                self.d.set(now + Self.failureBackoff, forKey: SettingsKeys.modelCatalogRetryAfter)
                Log.warn("Model catalog fetch failed, keeping source=\(self.sourceLabel) models=\(self.models.count)")
                completion?(false)
                return
            }
            self.d.set(now, forKey: SettingsKeys.modelCatalogLastCheck)
            self.d.set(0.0, forKey: SettingsKeys.modelCatalogRetryAfter)
            let changed = fresh != self.catalog
            self.catalog = fresh
            self.sourceLabel = source
            self.isFromRemote = true
            try? data.write(to: self.cacheFile, options: .atomic)
            Log.info("Model catalog updated source=\(source) updated=\(fresh.updated) "
                     + "models=\(fresh.models.count) changed=\(changed)")
            completion?(true)
        }
    }

    /// 按顺序试各个地址，成功即止。回调在主线程。
    private func fetch(index: Int, completion: @escaping (Data?, String) -> Void) {
        guard index < Self.remoteURLs.count, let url = URL(string: Self.remoteURLs[index]) else {
            DispatchQueue.main.async { completion(nil, "none") }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let ok = error == nil
                && (response as? HTTPURLResponse)?.statusCode == 200
                && (data?.isEmpty == false)
            if ok, let data = data {
                let host = url.host ?? "remote"
                DispatchQueue.main.async { completion(data, host) }
            } else {
                self?.fetch(index: index + 1, completion: completion)
            }
        }.resume()
    }
}
