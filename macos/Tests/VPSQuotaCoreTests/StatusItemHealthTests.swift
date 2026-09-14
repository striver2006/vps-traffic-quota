import Foundation
import Testing
import CoreGraphics
@testable import VPSQuotaCore

/// 状态项健康判定与重建退避。用例移植自 TokenBar 项目（几何取自 macOS 26 真机实测）。
///
/// 健康基线：菜单栏带高 30、visibleFrame 顶边 1410，健康状态项窗口 frame
/// `(2661, 1410, 80, 30)` —— maxY 正好贴齐屏幕顶边。
/// 故障态：右边缘与顶边都越出屏幕的 `(3332, 1417, 109, 24)`。
@Suite("状态项健康判定")
struct StatusItemHealthTests {

    /// 实测：菜单栏带高 30，visibleFrame 顶边 1410
    private let mainScreen = StatusItemHealth.ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 3440, height: 1440),
        visibleFrame: CGRect(x: 0, y: 80, width: 3440, height: 1330)
    )
    /// 健康状态项窗口的 AppKit frame（探针实测）
    private let healthyRect = CGRect(x: 2661, y: 1410, width: 80, height: 30)
    /// 线上故障态：顶边与右边缘都越出屏幕
    private let detachedRect = CGRect(x: 3332, y: 1417, width: 109, height: 24)

    private func makeSnapshot(
        hasItem: Bool = true,
        hasButton: Bool = true,
        isVisible: Bool = true,
        buttonWidth: CGFloat = 80,
        windowFrame: CGRect? = nil,
        windowNumber: Int? = 4096,
        registeredInWindowServer: Bool? = true,
        mirrored: Bool? = true,
        screens: [StatusItemHealth.ScreenGeometry]? = nil
    ) -> StatusItemHealth.Snapshot {
        StatusItemHealth.Snapshot(
            hasItem: hasItem,
            hasButton: hasButton,
            isVisible: isVisible,
            buttonWidth: buttonWidth,
            windowFrame: windowFrame ?? healthyRect,
            windowNumber: windowNumber,
            registeredInWindowServer: registeredInWindowServer,
            mirroredByMenuBarHost: mirrored,
            screens: screens ?? [mainScreen]
        )
    }

    // MARK: - evaluate

    @Test("几何与信号全正常时判健康")
    func healthyBaseline() {
        #expect(StatusItemHealth.evaluate(makeSnapshot()) == .healthy)
    }

    @Test("几何看着正常，但窗口没在窗口服务器注册 —— 图标一样看不见")
    func detachedWhenNotRegisteredInWindowServer() {
        #expect(StatusItemHealth.evaluate(makeSnapshot(registeredInWindowServer: false))
                == .detached(.notRegistered))
    }

    @Test("几何判定必须能独立命中，不依赖窗口服务器那条信号")
    func detachedByGeometryAloneWhenWindowServerSignalUnavailable() {
        for signal in [nil, true, false] as [Bool?] {
            let snapshot = makeSnapshot(windowFrame: detachedRect, registeredInWindowServer: signal)
            #expect(
                StatusItemHealth.evaluate(snapshot) == .detached(.offMenuBar),
                "reg=\(String(describing: signal)) 时几何判定应优先命中")
        }
    }

    @Test("查不到的信号绝不能当成掉线")
    func unavailableSignalsNeverCauseDetach() {
        #expect(StatusItemHealth.evaluate(makeSnapshot(registeredInWindowServer: nil)) == .healthy)
        #expect(StatusItemHealth.evaluate(makeSnapshot(mirrored: nil)) == .healthy)
    }

    @Test("真正的根因形态：几何停在正常位置、窗口也在，但控制中心没为它画镜像")
    func detachedWhenMenuBarHostDoesNotMirror() {
        #expect(StatusItemHealth.evaluate(makeSnapshot(mirrored: false)) == .detached(.notMirrored))
        // 镜像信号优先于窗口服务器注册信号
        #expect(StatusItemHealth.evaluate(
            makeSnapshot(registeredInWindowServer: false, mirrored: false)) == .detached(.notMirrored))
    }

    @Test("窗口缺失 / 窗口号为 0 / 窗口尺寸为 0 / 按钮宽度为 0")
    func detachedOnMissingPieces() {
        let noWindow = StatusItemHealth.Snapshot(
            hasItem: true, hasButton: true, isVisible: true, buttonWidth: 80,
            windowFrame: nil, windowNumber: 4096, registeredInWindowServer: true,
            screens: [mainScreen]
        )
        #expect(StatusItemHealth.evaluate(noWindow) == .detached(.noWindow))
        #expect(StatusItemHealth.evaluate(makeSnapshot(windowNumber: 0)) == .detached(.zeroWindowNumber))
        #expect(StatusItemHealth.evaluate(
            makeSnapshot(windowFrame: CGRect(x: 2661, y: 1410, width: 0, height: 0)))
            == .detached(.zeroWindowSize))
        #expect(StatusItemHealth.evaluate(makeSnapshot(buttonWidth: 0)) == .detached(.zeroButtonWidth))
    }

    @Test("窗口停在屏幕中间不是菜单栏")
    func detachedWhenWindowSitsInScreenMiddle() {
        #expect(StatusItemHealth.evaluate(
            makeSnapshot(windowFrame: CGRect(x: 1720, y: 700, width: 80, height: 30)))
            == .detached(.offMenuBar))
    }

    @Test("没有状态项 / 没有按钮")
    func noItemAndNoButton() {
        #expect(StatusItemHealth.evaluate(makeSnapshot(hasItem: false)) == .detached(.noItem))
        #expect(StatusItemHealth.evaluate(makeSnapshot(hasButton: false)) == .detached(.noButton))
    }

    @Test("isVisible 必须排在所有几何判定之前：用户 Cmd 拖走不该被当成故障重建")
    func userHiddenTakesPrecedenceOverGeometry() {
        #expect(StatusItemHealth.evaluate(makeSnapshot(isVisible: false)) == .userHidden)

        let hiddenAndDetached = StatusItemHealth.Snapshot(
            hasItem: true, hasButton: true, isVisible: false, buttonWidth: 0,
            windowFrame: nil, windowNumber: 0, registeredInWindowServer: false,
            screens: [mainScreen]
        )
        #expect(StatusItemHealth.evaluate(hiddenAndDetached) == .userHidden)
    }

    @Test("熄屏 / 显示器重配置中途（无屏幕）：绝不在这时重建")
    func indeterminateWhenNoScreens() {
        #expect(StatusItemHealth.evaluate(makeSnapshot(screens: [])) == .indeterminate)
    }

    @Test("副屏上的状态项也算健康")
    func healthyOnSecondaryScreen() {
        let secondary = StatusItemHealth.ScreenGeometry(
            frame: CGRect(x: 3440, y: 200, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 3440, y: 200, width: 1920, height: 1055)
        )
        let snapshot = makeSnapshot(
            windowFrame: CGRect(x: 4000, y: 1254, width: 80, height: 22),
            screens: [mainScreen, secondary]
        )
        #expect(StatusItemHealth.evaluate(snapshot) == .healthy)
    }

    @Test("菜单栏带下边界：带高 30 + 松弛 8 → 最低允许 maxY = 1402")
    func menuBarBandBottomBoundary() {
        let inside = makeSnapshot(windowFrame: CGRect(x: 2661, y: 1380, width: 80, height: 22))
        #expect(StatusItemHealth.evaluate(inside) == .healthy)

        let outside = makeSnapshot(windowFrame: CGRect(x: 2661, y: 1379, width: 80, height: 22))
        #expect(StatusItemHealth.evaluate(outside) == .detached(.offMenuBar))
    }

    @Test("健康态 maxY 正好等于屏幕顶边，只有真越出去才算掉线")
    func menuBarBandTopBoundary() {
        #expect(StatusItemHealth.evaluate(makeSnapshot()) == .healthy)

        let overshoot = makeSnapshot(windowFrame: CGRect(x: 2661, y: 1412, width: 80, height: 30))
        #expect(StatusItemHealth.evaluate(overshoot) == .detached(.offMenuBar))
    }

    @Test("右边缘越出屏幕 —— 故障态的另一个特征")
    func menuBarBandRightBoundary() {
        let overshoot = makeSnapshot(windowFrame: CGRect(x: 3361, y: 1410, width: 80, height: 30))
        #expect(StatusItemHealth.evaluate(overshoot) == .detached(.offMenuBar))
    }

    // MARK: - RebuildPolicy

    private let policy = StatusItemHealth.RebuildPolicy()

    private func decide(
        _ verdict: StatusItemHealth.Verdict = .detached(.offMenuBar),
        detachedRun: Int = 2,
        attempts: Int = 0,
        secondsSinceLastRebuild: TimeInterval? = nil
    ) -> StatusItemHealth.RebuildPolicy.Decision {
        let now = Date()
        return policy.decide(
            verdict: verdict,
            consecutiveDetached: detachedRun,
            attempts: attempts,
            now: now,
            lastRebuildAt: secondsSinceLastRebuild.map { now.addingTimeInterval(-$0) }
        )
    }

    @Test("非掉线判定一律不重建")
    func policyWaitsWhenHealthy() {
        #expect(decide(.healthy) == .wait(0))
        #expect(decide(.userHidden) == .wait(0))
        #expect(decide(.indeterminate) == .wait(0))
    }

    @Test("需要连续确认才动手")
    func policyNeedsConsecutiveConfirmations() {
        #expect(decide(detachedRun: 1) == .wait(0))
        #expect(decide(detachedRun: 2) == .rebuild)
    }

    @Test("退避窗口指数增长：30 / 60 / 120 秒")
    func policyBackoffGrowsExponentially() {
        guard case .wait(let first) = decide(attempts: 1, secondsSinceLastRebuild: 10) else {
            Issue.record("应仍在退避窗口内"); return
        }
        #expect(abs(first - 20) < 0.5)
        #expect(decide(attempts: 1, secondsSinceLastRebuild: 31) == .rebuild)

        guard case .wait(let second) = decide(attempts: 2, secondsSinceLastRebuild: 10) else {
            Issue.record("应仍在退避窗口内"); return
        }
        #expect(abs(second - 50) < 0.5)
        guard case .wait(let third) = decide(attempts: 3, secondsSinceLastRebuild: 10) else {
            Issue.record("应仍在退避窗口内"); return
        }
        #expect(abs(third - 110) < 0.5)
    }

    @Test("预算最后一次先清 autosave 再重建，之后放弃")
    func policyLastAttemptClearsAutosaveThenGivesUp() {
        #expect(decide(attempts: 4, secondsSinceLastRebuild: 300) == .resetAutosaveThenRebuild)
        #expect(decide(attempts: 5, secondsSinceLastRebuild: 900) == .giveUp)
    }

    @Test("连续健康够久后重建预算还回去")
    func policyResetsAttemptsAfterStablePeriod() {
        let now = Date()
        #expect(policy.shouldResetAttempts(now: now, healthySince: now.addingTimeInterval(-601)))
        #expect(!policy.shouldResetAttempts(now: now, healthySince: now.addingTimeInterval(-599)))
        #expect(!policy.shouldResetAttempts(now: now, healthySince: nil))
    }
}

/// `lsregister -dump` 解析：找出本 bundle id 下路径已不存在的陈旧注册。
/// 样本照抄真实 dump 的格式（80 个 `-` 分隔、字段值前对齐空白、path 末尾 ` (0x…)` 序号）。
@Suite("LaunchServices dump 解析")
struct LaunchServicesDumpParsingTests {
    private let separator = String(repeating: "-", count: 80)

    private func record(identifier: String, path: String, seq: String) -> String {
        """
        \(separator)
        container:                  / (0x4)
        path:                       \(path) (\(seq))
        identifier:                 \(identifier)
        version:                    1.0 ({length = 32, bytes = 0x01000000 ... })
        executable:                 Contents/MacOS/VPSQuota
        type code:                  'APPL' (4150504c)
        """
    }

    private var sampleDump: String {
        [
            "Checking data integrity......done.",
            record(identifier: "io.vpsquota.VPSTrafficQuota", path: "/Applications/VPSQuota.app", seq: "0x35d4"),
            record(identifier: "io.vpsquota.VPSTrafficQuota", path: "/Users/chenzhenbo/Work/vps-traffic-quota/macos/build/old/VPSQuota.app", seq: "0x2ecc"),
            record(identifier: "com.unidrop.client", path: "/Volumes/dmg.Qj9lpz/UniDrop.app", seq: "0x3e7c"),
            record(identifier: "io.vpsquota.VPSTrafficQuota", path: "/Users/chenzhenbo/Work/vps-traffic-quota/macos/build/VPSQuota.app", seq: "0x474c"),
            separator,
        ].joined(separator: "\n")
    }

    @Test("只找本 bundle id 的死记录，别的应用的不碰，序号后缀要剥掉")
    func findsOnlyOwnBundleStalePaths() {
        let existing: Set<String> = [
            "/Applications/VPSQuota.app",
            "/Users/chenzhenbo/Work/vps-traffic-quota/macos/build/VPSQuota.app",
        ]
        let stale = LaunchServicesJanitor.staleLaunchServicesPaths(
            inDump: sampleDump, bundleID: "io.vpsquota.VPSTrafficQuota"
        ) { existing.contains($0) }
        // UniDrop 的死记录不是我们的，不能碰；序号后缀必须被剥掉
        #expect(stale == ["/Users/chenzhenbo/Work/vps-traffic-quota/macos/build/old/VPSQuota.app"])
    }

    @Test("全部路径都存在时返回空")
    func returnsEmptyWhenAllPathsExist() {
        let stale = LaunchServicesJanitor.staleLaunchServicesPaths(
            inDump: sampleDump, bundleID: "io.vpsquota.VPSTrafficQuota"
        ) { _ in true }
        #expect(stale.isEmpty)
    }

    @Test("路径带空格、结尾没有分隔行也能解析")
    func handlesPathWithSpacesAndNoTrailingSeparator() {
        let dump = record(identifier: "com.unidrop.client", path: "/Volumes/UniDrop 1/UniDrop.app", seq: "0x411c")
        let stale = LaunchServicesJanitor.staleLaunchServicesPaths(
            inDump: dump, bundleID: "com.unidrop.client"
        ) { _ in false }
        #expect(stale == ["/Volumes/UniDrop 1/UniDrop.app"])
    }
}

/// 注销死记录时原位重建的 stub Info.plist：必须是可解析的 XML plist，
/// 且 CFBundleIdentifier 与要注销的记录一致（否则 `-u` 匹配不上）。
@Suite("stub Info.plist")
struct StubInfoPlistTests {
    @Test("是可解析的 plist，且 bundle id 与要注销的记录一致")
    func stubPlistIsReadablePropertyListWithOwnBundleID() throws {
        let data = LaunchServicesJanitor.stubInfoPlist(bundleID: "io.vpsquota.VPSTrafficQuota")
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        #expect(dict["CFBundleIdentifier"] == "io.vpsquota.VPSTrafficQuota")
        #expect(dict["CFBundlePackageType"] == "APPL")
        #expect(dict["CFBundleExecutable"] == "LSTombstone")
    }
}
