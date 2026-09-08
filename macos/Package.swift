// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VPSQuota",
    platforms: [.macOS(.v15)],
    targets: [
        // 纯逻辑 + 采集 + 存储。不含任何 UI，可被单元测试完整覆盖。
        .target(
            name: "VPSQuotaCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // 菜单栏应用本体。由 scripts/build-app.sh 组装成 .app bundle 后运行。
        .executableTarget(
            name: "VPSQuota",
            dependencies: ["VPSQuotaCore"]
        ),
        // 诊断用命令行工具：不启动 UI，直接验证 API Key / SSH 连通性与采集结果。
        .executableTarget(
            name: "vpsquota-cli",
            dependencies: ["VPSQuotaCore"]
        ),
        .testTarget(
            name: "VPSQuotaCoreTests",
            dependencies: ["VPSQuotaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
