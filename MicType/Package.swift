// swift-tools-version:6.0
import PackageDescription

// 5.0.0 起 MicType **只有云端识别**（OpenAI / 阿里云二选一），本机 Qwen3-ASR 整条链路删掉。
// 于是这份清单里没有任何第三方依赖了：MLX 那一串（mlx-swift-asr → mlx-swift → Metal 工具链）
// 是首次编译要等 5–15 分钟的唯一原因，也是 App 体积的大头。
let package = Package(
    name: "MicType",
    platforms: [
        .macOS("15.0")
    ],
    targets: [
        .executableTarget(
            name: "MicType",
            path: "Sources/MicType",
            swiftSettings: [
                // 源码按 Swift 5 语言模式编译（避免 Swift 6 严格并发检查）
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
