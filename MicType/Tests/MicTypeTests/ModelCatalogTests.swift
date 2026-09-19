import XCTest
@testable import MicType

/// 模型目录（model-catalog.json）的解码与版本比较。
/// 这份 JSON 是**发布接口**：改一次就会被所有已装版本当天读到，所以它的解析规则
/// （缺字段的默认值、认不出的格式怎么办、schemaVersion 的含义）必须钉死在测试里。
final class ModelCatalogTests: XCTestCase {

    // MARK: 解码

    private let goodJSON = """
    {
      "schemaVersion": 1,
      "updated": "2026-09-19",
      "models": [
        {
          "repo": "mlx-community/Qwen3-ASR-0.6B-6bit",
          "displayName": { "zh": "小模型", "en": "Small" },
          "sizeBytes": 861775040,
          "quant": "6bit",
          "languagesNote": { "zh": "中英最稳", "en": "Chinese and English" },
          "recommended": true,
          "recommendedFor": [],
          "minAppVersion": "4.0.0",
          "revision": null
        },
        {
          "repo": "mlx-community/Qwen3-ASR-1.7B-4bit",
          "displayName": { "zh": "大模型", "en": "Large" },
          "sizeBytes": 1607630579,
          "quant": "4bit",
          "languagesNote": { "zh": "阿语更准", "en": "Better Arabic" },
          "recommended": false,
          "recommendedFor": ["ar"],
          "minAppVersion": "4.0.0",
          "revision": null
        }
      ]
    }
    """

    func testDecodesModelsInOrder() throws {
        let catalog = try ModelCatalog.decode(Data(goodJSON.utf8))
        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertEqual(catalog.updated, "2026-09-19")
        XCTAssertEqual(catalog.models.map(\.repo),
                       ["mlx-community/Qwen3-ASR-0.6B-6bit", "mlx-community/Qwen3-ASR-1.7B-4bit"])
        XCTAssertEqual(catalog.models[0].sizeBytes, 861_775_040)
        XCTAssertEqual(catalog.models[1].quant, "4bit")
        XCTAssertNil(catalog.models[0].revision)
    }

    /// recommended 那一条是干净安装的默认；没人标 recommended 就退回第一条
    func testRecommendedModel() throws {
        let catalog = try ModelCatalog.decode(Data(goodJSON.utf8))
        XCTAssertEqual(catalog.recommendedModel?.repo, "mlx-community/Qwen3-ASR-0.6B-6bit")

        let noneRecommended = ModelCatalog(updated: "x", models: [
            CatalogModel(repo: "a/b", displayName: LocalizedText(zh: "a", en: "a"), sizeBytes: 1,
                         quant: "", languagesNote: LocalizedText(zh: "", en: ""), recommended: false),
        ])
        XCTAssertEqual(noneRecommended.recommendedModel?.repo, "a/b")
    }

    /// recommendedFor 比对大小写与空白不敏感；空语言代码永远不算命中
    func testRecommendedForLanguage() throws {
        let large = try ModelCatalog.decode(Data(goodJSON.utf8)).models[1]
        XCTAssertTrue(large.isRecommended(forLanguage: "ar"))
        XCTAssertTrue(large.isRecommended(forLanguage: " AR "))
        XCTAssertFalse(large.isRecommended(forLanguage: "zh"))
        XCTAssertFalse(large.isRecommended(forLanguage: ""))
    }

    /// 缺字段要按默认值读下来——目录里漏写一个 quant，不该让整份清单作废
    func testMissingFieldsFallBackToDefaults() throws {
        let json = """
        { "schemaVersion": 1, "updated": "", "models": [ { "repo": "x/y" } ] }
        """
        let catalog = try ModelCatalog.decode(Data(json.utf8))
        let model = try XCTUnwrap(catalog.models.first)
        XCTAssertEqual(model.repo, "x/y")
        XCTAssertEqual(model.displayName.localized, "x/y")   // 没给名字就显示仓库 ID
        XCTAssertEqual(model.sizeBytes, 0)
        XCTAssertEqual(model.quant, "")
        XCTAssertFalse(model.recommended)
        XCTAssertEqual(model.recommendedFor, [])
        XCTAssertEqual(model.minAppVersion, "")
    }

    /// 单条模型写坏（类型不对）只丢那一条，其余照用
    func testBrokenEntryIsDroppedNotFatal() throws {
        let json = """
        {
          "schemaVersion": 1, "updated": "x",
          "models": [
            { "repo": "good/one", "sizeBytes": 10 },
            { "repo": 42 },
            { "repo": "  " }
          ]
        }
        """
        let catalog = try ModelCatalog.decode(Data(json.utf8))
        XCTAssertEqual(catalog.models.map(\.repo), ["good/one"])
    }

    /// 未来格式一律拒收：读不懂的新目录绝不能把模型列表清空（调用方保留上一层兜底）
    func testUnsupportedSchemaVersionThrows() {
        let json = """
        { "schemaVersion": 2, "updated": "x", "models": [ { "repo": "a/b" } ] }
        """
        XCTAssertThrowsError(try ModelCatalog.decode(Data(json.utf8)))
    }

    /// 一条可用模型都没有 = 当作没拿到目录
    func testEmptyModelsThrows() {
        let json = """
        { "schemaVersion": 1, "updated": "x", "models": [] }
        """
        XCTAssertThrowsError(try ModelCatalog.decode(Data(json.utf8)))
        XCTAssertThrowsError(try ModelCatalog.decode(Data("not json".utf8)))
    }

    /// 内置兜底表本身必须是能用的（两档、恰好一个 recommended、体量都写了）
    func testBuiltInCatalogIsUsable() {
        let models = ModelCatalog.builtIn.models
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models.filter { $0.recommended }.count, 1)
        XCTAssertEqual(ModelCatalog.builtIn.recommendedModel?.repo, QwenModels.defaultRepo)
        XCTAssertTrue(models.contains { $0.repo == "mlx-community/Qwen3-ASR-1.7B-4bit" })
        XCTAssertTrue(models.allSatisfy { $0.sizeBytes > 0 })
    }

    /// 实测推翻了「阿语该换 1.7B」：0.6B + 词汇表热词 12.5% → 4.0%，1.7B 基本不吃热词（16.8%）。
    /// 所以目录里**不许**有任何语言专用推荐——那会让 ModelUpgrader 停止劝用户回到推荐档，
    /// 也会在设置页劝他下 1.6 GB 去解决一个词汇表就能解决的问题。
    func testNoModelIsRecommendedForASpecificLanguage() {
        for model in ModelCatalog.builtIn.models {
            XCTAssertTrue(model.recommendedFor.isEmpty,
                          "\(model.repo) 不该带 recommendedFor：\(model.recommendedFor)")
        }
        XCTAssertFalse(ModelCatalog.builtIn.models.contains { $0.isRecommended(forLanguage: "ar") })
    }

    /// 5-bit 那两档**不进目录**：实测它把中文数字随手改写成阿拉伯数字，阿语一个标点都不吐
    func testCatalogShipsNoFiveBitModels() {
        XCTAssertFalse(ModelCatalog.builtIn.models.contains { $0.quant.contains("5bit") })
    }

    /// 1.7B 那一档的体量必须是真实的 1.61 GB（历史上写过「约 1.1 GB」，差了 500 MB）
    func testLargeModelSizeIsAccurate() {
        let large = ModelCatalog.builtIn.models.first { $0.repo.contains("1.7B") }
        XCTAssertEqual(large?.sizeBytes, 1_607_630_579)
        XCTAssertTrue(QwenModels.sizeNote(bytes: large?.sizeBytes ?? 0).contains("1.61 GB"))
    }

    /// 三份同源的清单必须逐字一致：仓库根的 model-catalog.json（远端取的就是它）、
    /// App 内置资源里的那份、以及代码里的最后兜底。任何一份改了另两份没跟上，这条会红。
    func testRepoResourceAndBuiltInCatalogsAgree() throws {
        // …/MicType/Tests/MicTypeTests/ModelCatalogTests.swift → 上溯到仓库根
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile.deletingLastPathComponent()   // MicTypeTests
            .deletingLastPathComponent()                      // Tests
            .deletingLastPathComponent()                      // MicType
            .deletingLastPathComponent()                      // 仓库根
        let rootJSON = repoRoot.appendingPathComponent("model-catalog.json")
        let resourceJSON = repoRoot.appendingPathComponent("MicType/Resources/model-catalog.json")

        let rootData = try Data(contentsOf: rootJSON)
        let resourceData = try Data(contentsOf: resourceJSON)
        XCTAssertEqual(rootData, resourceData,
                       "model-catalog.json 的仓库根副本与 MicType/Resources 副本不一致")

        let fromFile = try ModelCatalog.decode(rootData)
        XCTAssertEqual(fromFile, ModelCatalog.builtIn,
                       "model-catalog.json 与 ModelCatalog.builtIn 不一致")
    }

    /// 发出去的目录里，每一条的 minAppVersion 都必须被**这一版 App 自己**满足。
    ///
    /// 为什么要钉死这一对：两边分别在两个文件里改，一旦目录先写了下一版的号（Info.plist 还没跟上），
    /// 用户就会在菜单栏和识别页看到一条无解的「新模型需要更新 MicType」——而那个模型此刻
    /// 明明在下拉框里、跑得好好的，去查 App 更新还会被告知已是最新。这是一条死路。
    /// 这里读的是仓库里的 Info.plist（不是 Bundle.main）：测试跑在哪个宿主里都得出同一个结论。
    func testBundledCatalogRunsOnThisAppVersion() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MicTypeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MicType
            .deletingLastPathComponent()   // 仓库根
        let plistData = try Data(contentsOf: repoRoot
            .appendingPathComponent("MicType/Resources/Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: plistData, format: nil) as? [String: Any])
        let appVersion = try XCTUnwrap(plist["CFBundleShortVersionString"] as? String)

        let catalog = try ModelCatalog.decode(
            try Data(contentsOf: repoRoot.appendingPathComponent("model-catalog.json")))
        for model in catalog.models + ModelCatalog.builtIn.models {
            XCTAssertTrue(AppVersionCompare.satisfiesMinimum(appVersion: appVersion,
                                                             minimum: model.minAppVersion),
                          "目录里 \(model.repo) 要求 \(model.minAppVersion)，而这一版 App 是 \(appVersion)")
        }
    }

    // MARK: 版本比较

    func testVersionCompare() {
        XCTAssertEqual(AppVersionCompare.compare("4.0.0", "4.0.0"), 0)
        XCTAssertEqual(AppVersionCompare.compare("4.0.1", "4.0.0"), 1)
        XCTAssertEqual(AppVersionCompare.compare("3.3.0", "4.0.0"), -1)
        // 段数不同按 0 补齐："4.0" == "4.0.0"，"4.0.1" > "4"
        XCTAssertEqual(AppVersionCompare.compare("4.0", "4.0.0"), 0)
        XCTAssertEqual(AppVersionCompare.compare("4.0.1", "4"), 1)
        // 十进制不是字典序：3.10 > 3.9
        XCTAssertEqual(AppVersionCompare.compare("3.10.0", "3.9.9"), 1)
        // 每段只取前导数字
        XCTAssertEqual(AppVersionCompare.compare("4.0.0-beta2", "4.0.0"), 0)
    }

    func testSatisfiesMinimum() {
        XCTAssertTrue(AppVersionCompare.satisfiesMinimum(appVersion: "4.0.0", minimum: "4.0.0"))
        XCTAssertTrue(AppVersionCompare.satisfiesMinimum(appVersion: "4.1.0", minimum: "4.0.0"))
        XCTAssertFalse(AppVersionCompare.satisfiesMinimum(appVersion: "3.3.0", minimum: "4.0.0"))
        // 目录漏写 / 写坏 minAppVersion 一律算够——不能让一个本来能用的模型变成「需要更新」
        XCTAssertTrue(AppVersionCompare.satisfiesMinimum(appVersion: "3.3.0", minimum: ""))
        XCTAssertTrue(AppVersionCompare.satisfiesMinimum(appVersion: "3.3.0", minimum: "   "))
        XCTAssertTrue(AppVersionCompare.satisfiesMinimum(appVersion: "3.3.0", minimum: "latest"))
    }

    // MARK: 体量文案

    func testSizeNote() {
        // 十进制口径，和 HF 页面 / Finder 一致
        XCTAssertTrue(QwenModels.sizeNote(bytes: 861_775_040).contains("862 MB"))
        XCTAssertTrue(QwenModels.sizeNote(bytes: 1_607_630_579).contains("1.61 GB"))
        // 1.01 GB 和 1.61 GB 在界面上必须分得出来（两位小数的理由）
        XCTAssertTrue(QwenModels.sizeNote(bytes: 1_010_800_000).contains("1.01 GB"))
        // 目录漏写 sizeBytes 时不显示「约 0 MB」
        XCTAssertEqual(QwenModels.sizeNote(bytes: 0), "")
        XCTAssertEqual(QwenModels.sizeNote(bytes: -5), "")
    }

    // MARK: HF 清单解析

    /// 下载与升级校验共用这一段解析，跳过隐藏文件与 .md 的规则必须和下载行为一致
    func testManifestParsingSkipsDocsAndHiddenFiles() {
        let json = """
        [
          {"type":"file","size":1519,"path":".gitattributes"},
          {"type":"file","size":1008,"path":"README.md"},
          {"type":"file","size":7187,"path":"config.json"},
          {"type":"file","size":857233233,"path":"model.safetensors"},
          {"type":"directory","size":0,"path":"extra"}
        ]
        """
        let files = QwenModelDownloader.parseManifest(Data(json.utf8))
        XCTAssertEqual(files.map(\.path), ["config.json", "model.safetensors"])
        XCTAssertEqual(files.last?.size, 857_233_233)
        // 坏响应给空清单（调用方据此换镜像源，而不是当成「仓库是空的」）
        XCTAssertTrue(QwenModelDownloader.parseManifest(Data("nope".utf8)).isEmpty)
    }

    /// 清单来自 hf-mirror.com（第三方镜像），路径会被直接拼成本地落盘路径 → 逃逸路径一条都不许进清单。
    /// 注意 `../x` 恰好会被"跳过隐藏文件"的规则挡掉，那是巧合；真正危险的是非开头的 `..` 段。
    func testManifestParsingRejectsPathTraversal() {
        let json = """
        [
          {"type":"file","size":512,"path":"weights/../../../../Library/LaunchAgents/com.evil.plist"},
          {"type":"file","size":512,"path":"/etc/cron.d/evil"},
          {"type":"file","size":512,"path":"~/Library/LaunchAgents/evil.plist"},
          {"type":"file","size":512,"path":"a\\\\..\\\\..\\\\evil"},
          {"type":"file","size":512,"path":"weights//evil"},
          {"type":"file","size":512,"path":"a/./b"},
          {"type":"file","size":7187,"path":"config.json"}
        ]
        """
        let files = QwenModelDownloader.parseManifest(Data(json.utf8))
        XCTAssertEqual(files.map(\.path), ["config.json"],
                       "镜像给的逃逸路径必须一条都不进清单")
    }

    /// 形状校验与落盘前的前缀校验分别钉一遍：两道都在，中间不留缝
    func testManifestPathSafetyAndDestination() {
        for good in ["config.json", "weights/model.safetensors", "a/b/c.json", "model-00001-of-2.bin"] {
            XCTAssertTrue(QwenModelDownloader.isSafeManifestPath(good), good)
        }
        for bad in ["", "/abs/x", "~/x", "a/../../x", "..", "a/..", "./x", "a//b", "a/", "a\\b",
                    "x\u{0}y", String(repeating: "a", count: 513)] {
            XCTAssertFalse(QwenModelDownloader.isSafeManifestPath(bad), "应当拒绝：\(bad)")
        }
        let dir = URL(fileURLWithPath: "/tmp/mictype-model-test")
        XCTAssertEqual(QwenModelDownloader.safeDestination(in: dir, path: "weights/a.bin")?.path,
                       "/tmp/mictype-model-test/weights/a.bin")
        XCTAssertNil(QwenModelDownloader.safeDestination(in: dir, path: "a/../../../etc/passwd"))
        XCTAssertNil(QwenModelDownloader.safeDestination(in: dir, path: "/etc/passwd"))
        // 目录本身不是合法落点
        XCTAssertNil(QwenModelDownloader.safeDestination(in: dir, path: "."))
    }

    /// 内容指纹取的是 LFS 的 oid（权重文件走 LFS），没有 LFS 时取普通 oid
    func testManifestParsingKeepsContentOIDs() {
        let json = """
        [
          {"type":"file","size":7187,"path":"config.json","oid":"abc123"},
          {"type":"file","size":857233233,"path":"model.safetensors","oid":"pointer",
           "lfs":{"oid":"sha256:deadbeef","size":857233233}}
        ]
        """
        let files = QwenModelDownloader.parseManifest(Data(json.utf8))
        XCTAssertEqual(files.first?.oid, "abc123")
        XCTAssertEqual(files.last?.oid, "sha256:deadbeef")
    }

    // MARK: 清单指纹（「有没有新修订」比的就是它）

    /// 指纹只认**会被下载的那些文件**：改模型卡（.md 压根不进清单）不该换来 862 MB 重下
    func testManifestFingerprintTracksFilesNotCommits() {
        let base = [
            QwenModelDownloader.ManifestFile(path: "config.json", size: 7187, oid: "a"),
            QwenModelDownloader.ManifestFile(path: "model.safetensors", size: 857_233_233, oid: "b"),
        ]
        // 同一份清单，顺序不同 → 同一个指纹（HF 的返回顺序不稳定，不能因此谎报有更新）
        XCTAssertEqual(QwenModelDownloader.manifestFingerprint(base),
                       QwenModelDownloader.manifestFingerprint(base.reversed()))
        // 大小变了 → 指纹变
        let resized = [base[0], QwenModelDownloader.ManifestFile(path: "model.safetensors",
                                                                 size: 857_233_999, oid: "b")]
        XCTAssertNotEqual(QwenModelDownloader.manifestFingerprint(base),
                          QwenModelDownloader.manifestFingerprint(resized))
        // 大小没变但内容变了（重新量化出同样大小的权重）→ oid 变，指纹照样变
        let recontented = [base[0], QwenModelDownloader.ManifestFile(path: "model.safetensors",
                                                                     size: 857_233_233, oid: "c")]
        XCTAssertNotEqual(QwenModelDownloader.manifestFingerprint(base),
                          QwenModelDownloader.manifestFingerprint(recontented))
        // 多一个文件 → 指纹变；空清单不崩
        XCTAssertNotEqual(QwenModelDownloader.manifestFingerprint(base),
                          QwenModelDownloader.manifestFingerprint(
                            base + [QwenModelDownloader.ManifestFile(path: "extra.json", size: 1)]))
        XCTAssertFalse(QwenModelDownloader.manifestFingerprint([]).isEmpty)
    }

    // MARK: 目录检查的节流

    /// 成功之后 24 小时不再查；一次失败只退避半小时——"启动那一刻还没联上网"
    /// 不等于"今天查过了"，否则用户整天在线却一整天看不到新模型
    func testCatalogCheckThrottle() {
        let now: TimeInterval = 1_000_000
        let day = ModelCatalogStore.checkInterval
        // 从来没成功过 → 查
        XCTAssertTrue(ModelCatalogStore.isDue(now: now, lastSuccess: 0, retryAfter: 0))
        // 刚成功过 → 不查
        XCTAssertFalse(ModelCatalogStore.isDue(now: now, lastSuccess: now - 60, retryAfter: 0))
        // 满 24 小时 → 查
        XCTAssertTrue(ModelCatalogStore.isDue(now: now, lastSuccess: now - day, retryAfter: 0))
        // 刚失败过（退避窗口还没过）→ 不查
        XCTAssertFalse(ModelCatalogStore.isDue(now: now, lastSuccess: 0, retryAfter: now + 600))
        // 退避窗口过了、且从没成功过 → 查（失败不该把窗口推成一整天）
        XCTAssertTrue(ModelCatalogStore.isDue(now: now, lastSuccess: 0, retryAfter: now - 1))
    }
}
