// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MicType",
    platforms: [
        // Qwen3-ASR(MLX) 引擎要求 macOS 15+、Apple Silicon
        .macOS("15.0")
    ],
    dependencies: [
        // Qwen3-ASR 推理引擎（MLX），锁定 commit 保证可复现
        .package(url: "https://github.com/ontypehq/mlx-swift-asr",
                 revision: "f8ea5e6e76824eae903580fcfab0ef15e207b479")
    ],
    targets: [
        .executableTarget(
            name: "MicType",
            dependencies: [
                .product(name: "MLXASR", package: "mlx-swift-asr"),
            ],
            path: "Sources/MicType",
            swiftSettings: [
                // 源码按 Swift 5 语言模式编译（避免 Swift 6 严格并发检查）
                .swiftLanguageMode(.v5)
            ]
        ),
        // 离线诊断 CLI（长音频失败模式 / 各语言质量实测）——独立可执行，App 不依赖它
        .executableTarget(
            name: "mictype-asr-probe",
            dependencies: [
                .product(name: "MLXASR", package: "mlx-swift-asr"),
            ],
            path: "Sources/ASRProbe",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // 纯函数层单测（词表替换 / 伪影与口水词过滤 / 润色保真校验）——不碰 UI、不碰网络
        .testTarget(
            name: "MicTypeTests",
            dependencies: ["MicType"],
            path: "Tests/MicTypeTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
