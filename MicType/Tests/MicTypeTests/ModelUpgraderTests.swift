import XCTest
@testable import MicType

/// 升级判定与清理选择。
/// 这两个判断一个决定要不要花掉用户几百 MB 流量，一个决定删不删他硬盘上的模型——
/// 所以它们是纯函数，并且每一条产品纪律（不劝用户换回来、要求更高版本就别假装能装、
/// 选中的模型永远不删）都在下面有一条对应的断言。
final class ModelUpgraderTests: XCTestCase {

    private let small = "mlx-community/Qwen3-ASR-0.6B-6bit"
    private let large = "mlx-community/Qwen3-ASR-1.7B-4bit"
    private let next = "mlx-community/Qwen4-ASR-1B-4bit"

    private func model(_ repo: String,
                       recommended: Bool = false,
                       recommendedFor: [String] = [],
                       minAppVersion: String = "4.0.0") -> CatalogModel {
        CatalogModel(repo: repo,
                     displayName: LocalizedText(zh: repo, en: repo),
                     sizeBytes: 1_000_000_000,
                     quant: "4bit",
                     languagesNote: LocalizedText(zh: "", en: ""),
                     recommended: recommended,
                     recommendedFor: recommendedFor,
                     minAppVersion: minAppVersion)
    }

    /// 当前这份目录（推荐档 = 已装的那一档）：没什么可提示的
    func testNothingToOfferWhenInstalledIsRecommended() {
        let catalog = [model(small, recommended: true), model(large, recommendedFor: ["ar"])]
        let decision = ModelUpgradeLogic.decide(installedRepo: small,
                                                catalog: catalog,
                                                appVersion: "4.0.0",
                                                languageCode: "",
                                                revisionUpdateAvailable: false,
                                                dismissedRepo: nil)
        XCTAssertEqual(decision, .none)
    }

    /// 目录换代（新模型成了推荐档）→ 提示升级
    func testNewRecommendedModelIsOffered() {
        let catalog = [model(next, recommended: true), model(small), model(large, recommendedFor: ["ar"])]
        let decision = ModelUpgradeLogic.decide(installedRepo: small,
                                                catalog: catalog,
                                                appVersion: "4.0.0",
                                                languageCode: "",
                                                revisionUpdateAvailable: false,
                                                dismissedRepo: nil)
        XCTAssertEqual(decision, .upgrade(repo: next))
    }

    /// 铁律：用户为阿语专门选了 1.7B（目录里标着 recommendedFor: ["ar"]），
    /// 就绝不拿通用推荐档去劝他换回小模型——那是替用户做主
    func testLanguageSpecificChoiceIsNotOverridden() {
        let catalog = [model(small, recommended: true), model(large, recommendedFor: ["ar"])]
        let decision = ModelUpgradeLogic.decide(installedRepo: large,
                                                catalog: catalog,
                                                appVersion: "4.0.0",
                                                languageCode: "ar",
                                                revisionUpdateAvailable: false,
                                                dismissedRepo: nil)
        XCTAssertEqual(decision, .none)
    }

    /// 同一个人把识别语言换回中文后，1.7B 就不再是「为他的语言选的」→ 可以提示推荐档
    func testSameSetupIsOfferedOnceLanguageNoLongerMatches() {
        let catalog = [model(small, recommended: true), model(large, recommendedFor: ["ar"])]
        let decision = ModelUpgradeLogic.decide(installedRepo: large,
                                                catalog: catalog,
                                                appVersion: "4.0.0",
                                                languageCode: "zh",
                                                revisionUpdateAvailable: false,
                                                dismissedRepo: nil)
        XCTAssertEqual(decision, .upgrade(repo: small))
    }

    /// 新模型要求更高的 App 版本：只说「需要更新 MicType」，绝不给一个装了也跑不起来的按钮
    func testModelRequiringNewerAppRoutesToAppUpdate() {
        let catalog = [model(next, recommended: true, minAppVersion: "4.2.0"), model(small)]
        let decision = ModelUpgradeLogic.decide(installedRepo: small,
                                                catalog: catalog,
                                                appVersion: "4.0.0",
                                                languageCode: "",
                                                revisionUpdateAvailable: false,
                                                dismissedRepo: nil)
        XCTAssertEqual(decision, .needsAppUpdate(repo: next, minAppVersion: "4.2.0"))
    }

    /// minAppVersion 正好等于当前版本 = 够用
    func testMinAppVersionEqualIsAllowed() {
        let catalog = [model(next, recommended: true, minAppVersion: "4.0.0"), model(small)]
        let decision = ModelUpgradeLogic.decide(installedRepo: small,
                                                catalog: catalog,
                                                appVersion: "4.0.0",
                                                languageCode: "",
                                                revisionUpdateAvailable: false,
                                                dismissedRepo: nil)
        XCTAssertEqual(decision, .upgrade(repo: next))
    }

    /// 点过「以后再说」的那一档不再提示；但换成别的新模型照样提示
    func testDismissedOfferIsSuppressedPerRepo() {
        let catalog = [model(next, recommended: true), model(small)]
        XCTAssertEqual(ModelUpgradeLogic.decide(installedRepo: small, catalog: catalog,
                                                appVersion: "4.0.0", languageCode: "",
                                                revisionUpdateAvailable: false,
                                                dismissedRepo: next),
                       .none)
        XCTAssertEqual(ModelUpgradeLogic.decide(installedRepo: small, catalog: catalog,
                                                appVersion: "4.0.0", languageCode: "",
                                                revisionUpdateAvailable: false,
                                                dismissedRepo: "someone/else"),
                       .upgrade(repo: next))
    }

    /// 没有更好的可换时，才看已装仓库自己有没有新修订
    func testRevisionUpdateOnlyWhenNoBetterModel() {
        let catalog = [model(small, recommended: true), model(large, recommendedFor: ["ar"])]
        XCTAssertEqual(ModelUpgradeLogic.decide(installedRepo: small, catalog: catalog,
                                                appVersion: "4.0.0", languageCode: "",
                                                revisionUpdateAvailable: true,
                                                dismissedRepo: nil),
                       .refresh(repo: small))
        // 换代提示优先于同仓库修订（换个更好的模型比刷新旧模型更有价值）
        let renewed = [model(next, recommended: true), model(small)]
        XCTAssertEqual(ModelUpgradeLogic.decide(installedRepo: small, catalog: renewed,
                                                appVersion: "4.0.0", languageCode: "",
                                                revisionUpdateAvailable: true,
                                                dismissedRepo: nil),
                       .upgrade(repo: next))
    }

    /// 已装的仓库根本不在目录里（被下架）→ 提示换到推荐档
    func testRetiredInstalledModelIsOfferedAnUpgrade() {
        let catalog = [model(small, recommended: true)]
        XCTAssertEqual(ModelUpgradeLogic.decide(installedRepo: "old/retired-model", catalog: catalog,
                                                appVersion: "4.0.0", languageCode: "",
                                                revisionUpdateAvailable: false,
                                                dismissedRepo: nil),
                       .upgrade(repo: small))
    }

    /// 目录一条都没有（离线首启动、JSON 读坏）→ 什么都不提示，绝不瞎推荐
    func testEmptyCatalogOffersNothing() {
        XCTAssertEqual(ModelUpgradeLogic.decide(installedRepo: small, catalog: [],
                                                appVersion: "4.0.0", languageCode: "",
                                                revisionUpdateAvailable: false,
                                                dismissedRepo: nil),
                       .none)
    }

    // MARK: 清理选择

    /// 升级留下的旧模型该删；目录里还列着、只是没被选中的那份（用户的另一档）不能删
    func testCleanupRemovesPendingButKeepsOtherCatalogModels() {
        let victims = ModelUpgradeLogic.directoriesToRemove(existingRepos: [small, large, next],
                                                           selectedRepo: next,
                                                           catalogRepos: [next, small, large],
                                                           pendingRepos: [small])
        XCTAssertEqual(victims, [small])
    }

    /// 孤儿目录（目录里已经没有、又没被选中）一并清掉
    func testCleanupRemovesOrphans() {
        let victims = ModelUpgradeLogic.directoriesToRemove(existingRepos: ["old/gone", small, large],
                                                           selectedRepo: small,
                                                           catalogRepos: [small],
                                                           pendingRepos: [])
        // large 不在目录里了也算孤儿；selected 的 small 永远留着
        XCTAssertEqual(victims, ["old/gone", large])
    }

    /// 铁律：选中的模型永远不删——哪怕它被错误地写进了待清理列表
    func testCleanupNeverRemovesSelectedModel() {
        let victims = ModelUpgradeLogic.directoriesToRemove(existingRepos: [small, large],
                                                           selectedRepo: small,
                                                           catalogRepos: [small, large],
                                                           pendingRepos: [small, large])
        XCTAssertEqual(victims, [large])
        XCTAssertFalse(victims.contains(small))
    }

    /// 重复项只出现一次；磁盘上不存在的待清理项不进结果（没有就不必删）
    func testCleanupDeduplicatesAndIgnoresMissingDirectories() {
        let victims = ModelUpgradeLogic.directoriesToRemove(existingRepos: [large, large],
                                                           selectedRepo: small,
                                                           catalogRepos: [small, large],
                                                           pendingRepos: [large, "never/downloaded"])
        XCTAssertEqual(victims, [large])
    }

    /// 什么都不该删的情形：只有选中的那一个目录
    func testCleanupNothingToDo() {
        XCTAssertTrue(ModelUpgradeLogic.directoriesToRemove(existingRepos: [small],
                                                            selectedRepo: small,
                                                            catalogRepos: [small],
                                                            pendingRepos: []).isEmpty)
    }

    // MARK: 文件校验

    func testMismatchedFilesDetectsMissingAndWrongSize() {
        let manifest = [
            QwenModelDownloader.ManifestFile(path: "config.json", size: 7187),
            QwenModelDownloader.ManifestFile(path: "model.safetensors", size: 857_233_233),
            QwenModelDownloader.ManifestFile(path: "vocab.json", size: 0),   // 服务端没给大小
        ]
        // 全对
        XCTAssertTrue(ModelUpgradeLogic.mismatchedFiles(
            manifest: manifest,
            localSizes: ["config.json": 7187, "model.safetensors": 857_233_233, "vocab.json": 12]).isEmpty)
        // 缺文件
        XCTAssertEqual(ModelUpgradeLogic.mismatchedFiles(
            manifest: manifest,
            localSizes: ["config.json": 7187, "vocab.json": 12]), ["model.safetensors"])
        // 大小不对（下载被截断）
        XCTAssertEqual(ModelUpgradeLogic.mismatchedFiles(
            manifest: manifest,
            localSizes: ["config.json": 7187, "model.safetensors": 1024, "vocab.json": 12]),
                       ["model.safetensors"])
        // size<=0 的清单项只要求存在，不比大小
        XCTAssertEqual(ModelUpgradeLogic.mismatchedFiles(
            manifest: manifest,
            localSizes: ["config.json": 7187, "model.safetensors": 857_233_233]), ["vocab.json"])
    }

    // MARK: 校验用的合成音频

    func testProbeSamples() {
        let samples = ModelUpgradeLogic.probeSamples()
        // 1 秒 16 kHz：必须远超库里那道「<400 sample 直接返回空文本」的短路，否则「跑通」证明不了什么
        XCTAssertEqual(samples.count, 16_000)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 0.05001 })
        // 真的有波形（不是一片静音）
        XCTAssertTrue(samples.contains { abs($0) > 0.01 })
        XCTAssertEqual(ModelUpgradeLogic.probeSamples(seconds: 0.5).count, 8_000)
        XCTAssertFalse(ModelUpgradeLogic.probeSamples(seconds: 0).isEmpty)
    }
}
