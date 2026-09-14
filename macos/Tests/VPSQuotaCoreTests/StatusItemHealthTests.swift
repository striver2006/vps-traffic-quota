import Foundation
import Testing
import CoreGraphics
@testable import VPSQuotaCore

/// 状态项健康判定与重建退避（几何取自 macOS 26 真机实测）。
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
        // 结构性预算是 3 次，attempts=3 时已经耗尽，不再有第三段退避窗口
        #expect(decide(attempts: 3, secondsSinceLastRebuild: 10) == .giveUp)
    }

    @Test("窗口停在屏幕外（从未被布局）判为没拿到槽位，而不是几何跑飞")
    func neverLaidOutWindowIsNotMirrored() {
        // 真机实测（2026-09-14）：被拉黑时重建出来的状态项窗口永远停在 (0, -22)，
        // ControlCenter 不给槽位 AppKit 就不布局它，而且不会自己恢复。
        // 判成 offMenuBar 会让它走结构性重建梯，永远到不了 blockedBySystem。
        let neverLaidOut = makeSnapshot(windowFrame: CGRect(x: 0, y: -22, width: 79, height: 22))
        #expect(StatusItemHealth.evaluate(neverLaidOut) == .detached(.notMirrored))

        // 镜像信号查不到时同样成立 —— 这正是那条路径上的实际形态
        let noMirrorSignal = makeSnapshot(
            windowFrame: CGRect(x: 0, y: -22, width: 79, height: 22), mirrored: nil)
        #expect(StatusItemHealth.evaluate(noMirrorSignal) == .detached(.notMirrored))

        // 对照：在屏幕内但越出菜单栏带，仍然是结构性的 offMenuBar（重建对它有用）
        #expect(StatusItemHealth.evaluate(makeSnapshot(windowFrame: detachedRect))
                == .detached(.offMenuBar))
    }

    @Test("预算最后一次先清 autosave 再重建，之后放弃")
    func policyLastAttemptClearsAutosaveThenGivesUp() {
        #expect(decide(attempts: 2, secondsSinceLastRebuild: 300) == .resetAutosaveThenRebuild)
        #expect(decide(attempts: 3, secondsSinceLastRebuild: 900) == .giveUp)
    }

    @Test("连续健康够久后重建预算还回去")
    func policyResetsAttemptsAfterStablePeriod() {
        let now = Date()
        #expect(policy.shouldResetAttempts(now: now, healthySince: now.addingTimeInterval(-601)))
        #expect(!policy.shouldResetAttempts(now: now, healthySince: now.addingTimeInterval(-599)))
        #expect(!policy.shouldResetAttempts(now: now, healthySince: nil))
    }
}


/// 自愈编排。核心不变量：**确认被系统拉黑之后，永远不再重建。**
/// 拉黑按 bundle id 命中，每个新 PID 照样秒拒；继续重建只会让图标反复闪、
/// 还可能打乱它在菜单栏里的排序。
@Suite("自愈状态机")
struct SelfHealingMachineTests {

    private let now = Date()
    private func machine() -> StatusItemHealth.SelfHealingMachine { .init() }

    /// 连喂 n 次同一个判定，返回每次的动作
    @discardableResult
    private func feed(
        _ machine: inout StatusItemHealth.SelfHealingMachine,
        _ verdict: StatusItemHealth.Verdict,
        times: Int,
        secondsApart: TimeInterval = 0
    ) -> [StatusItemHealth.SelfHealingMachine.Action] {
        (0..<times).map { i in
            machine.advance(verdict: verdict, now: now.addingTimeInterval(Double(i) * secondsApart))
        }
    }

    /// 推到拉黑终态：确认两次 → 重建一次 → 再确认两次 → 判定拉黑。
    /// 重建之后要重新确认，是刻意的：宁可晚判，也不能给用户弹一条假横幅。
    private func blockedMachine() -> StatusItemHealth.SelfHealingMachine {
        var m = machine()
        feed(&m, .detached(.notMirrored), times: 4, secondsApart: 20)
        return m
    }

    @Test("notMirrored 确认两次才重建，重建后重新确认，再无镜像即判定拉黑")
    func mirrorRebuildsOnceThenDeclaresBlocked() {
        var m = machine()
        let actions = feed(&m, .detached(.notMirrored), times: 4, secondsApart: 20)
        #expect(actions[0] == .probe(15))                      // 第一次只是确认
        #expect(actions[1] == .rebuild(clearAutosave: false))   // 连续第二次才动手
        #expect(actions[2] == .probe(15))                      // 重建后重新确认
        #expect(actions[3] == .declareBlocked)                  // 镜像预算用完 → 判定拉黑
        #expect(m.state == .blockedBySystem)
        #expect(m.mirrorRebuilds == 1)
    }

    @Test("进入拉黑终态后永不重建")
    func neverRebuildsAfterBlocked() {
        var m = blockedMachine()
        // 拉黑期间就算被判成别的掉线形态，也一样不重建 —— 图标压根没拿到菜单栏槽位，
        // 这时的任何 detached 都不该触发动作
        let later = feed(&m, .detached(.notMirrored), times: 20, secondsApart: 60)
            + feed(&m, .detached(.offMenuBar), times: 5, secondsApart: 60)
        #expect(later.allSatisfy { $0 == .probe(60) })
        #expect(m.mirrorRebuilds == 1)
        #expect(m.state == .blockedBySystem)
    }

    @Test("用户放行后自动转健康，并把镜像重建预算还回去")
    func recoversWhenUserAllows() {
        var m = blockedMachine()
        #expect(m.advance(verdict: .healthy, now: now) == .recovered)
        if case .healthy = m.state {} else { Issue.record("应回到 healthy，实际 \(m.state)") }
        #expect(m.mirrorRebuilds == 0)
        // 还回预算之后，再被拉黑一次还能重新走一轮"重建 → 判定"
        #expect(feed(&m, .detached(.notMirrored), times: 2, secondsApart: 20).last
                == .rebuild(clearAutosave: false))
    }

    @Test("recovered 与 declareBlocked 都只发一次")
    func edgeActionsFireOnce() {
        var m = blockedMachine()
        #expect(feed(&m, .detached(.notMirrored), times: 3, secondsApart: 60)
                .allSatisfy { $0 == .probe(60) })          // 不重复 declareBlocked

        #expect(m.advance(verdict: .healthy, now: now) == .recovered)
        #expect(m.advance(verdict: .healthy, now: now) == .none)   // 不重复 recovered
    }

    @Test("结构性掉线仍走完整退避梯，最后一次先清 autosave")
    func structuralDetachStillRebuilds() {
        var m = machine()
        func step(_ t: Date) -> StatusItemHealth.SelfHealingMachine.Action {
            m.advance(verdict: .detached(.offMenuBar), now: t)
        }
        func expectProbe(_ action: StatusItemHealth.SelfHealingMachine.Action, _ seconds: TimeInterval) {
            guard case .probe(let wait) = action else {
                Issue.record("应是 probe，实际 \(action)"); return
            }
            #expect(abs(wait - seconds) < 0.5)
        }

        // 第一轮：确认两次就重建
        expectProbe(step(now), 15)
        #expect(step(now) == .rebuild(clearAutosave: false))
        #expect(m.attempts == 1)

        // 重建后连续计数清零，要重新确认；30 秒退避窗口没到只能等
        var t = now.addingTimeInterval(5)
        expectProbe(step(t), 15)
        expectProbe(step(t), 25)

        // 退避窗口过了：连续计数还在，下一拍直接重建
        t = now.addingTimeInterval(400)
        #expect(step(t) == .rebuild(clearAutosave: false))
        #expect(m.attempts == 2)
        expectProbe(step(t), 15)
        expectProbe(step(t), 60)      // 第二段退避翻倍

        // 预算最后一次：先清掉可能被写坏的持久化位置键再重建
        t = now.addingTimeInterval(2000)
        #expect(step(t) == .rebuild(clearAutosave: true))
        #expect(m.attempts == 3)
        expectProbe(step(t), 15)
        #expect(step(t) == .giveUp)
        #expect(m.state != .blockedBySystem)   // 结构性耗尽不等于被拉黑
    }

    @Test("indeterminate 不计入连续计数，也不触发重建")
    func indeterminateNeverCounts() {
        var m = machine()
        #expect(feed(&m, .indeterminate, times: 10).allSatisfy { $0 == .probe(15) })
        #expect(m.state == .unknown)
        #expect(m.attempts == 0)
        // 夹在掉线中间的 indeterminate 也不该打断确认计数
        _ = m.advance(verdict: .detached(.notMirrored), now: now)
        _ = m.advance(verdict: .indeterminate, now: now)
        #expect(m.advance(verdict: .detached(.notMirrored), now: now)
                == .rebuild(clearAutosave: false))
    }

    @Test("userHidden 只尝试一次拉回可见")
    func userHiddenForcesVisibleOnce() {
        var m = machine()
        #expect(feed(&m, .userHidden, times: 3) == [.forceVisibleOnce, .none, .none])
    }

    @Test("拉黑期间用户把图标拖走：拉黑判断不再成立，撤掉告知")
    func userHiddenClearsBlockedState() {
        var m = blockedMachine()
        #expect(m.advance(verdict: .userHidden, now: now) == .recovered)
        #expect(m.state == .unknown)
    }

    @Test("唤醒只清连续计数，不清重建预算、不解除拉黑")
    func resetDetachedRunKeepsBudgets() {
        var m = machine()
        feed(&m, .detached(.offMenuBar), times: 2)
        #expect(m.attempts == 1)
        m.resetDetachedRun()
        #expect(m.state == .unknown)
        #expect(m.attempts == 1)          // 预算没被刷掉

        var blocked = blockedMachine()
        blocked.resetDetachedRun()
        #expect(blocked.state == .blockedBySystem)   // 拉黑不会因为唤醒而解除
    }

    @Test("连续健康够久，两份重建预算都还回去")
    func stableHealthResetsBudgets() {
        var m = machine()
        feed(&m, .detached(.offMenuBar), times: 2)
        #expect(m.attempts == 1)

        _ = m.advance(verdict: .healthy, now: now)
        _ = m.advance(verdict: .healthy, now: now.addingTimeInterval(599))
        #expect(m.attempts == 1)
        _ = m.advance(verdict: .healthy, now: now.addingTimeInterval(601))
        #expect(m.attempts == 0)
    }
}

/// 控制中心镜像匹配。
@Suite("菜单栏镜像匹配")
struct MenuBarMirrorTests {

    /// 健康状态项窗口的 frame（与健康判定用例同一组实测数据）
    private let itemFrame = CGRect(x: 2661, y: 1410, width: 80, height: 30)

    private func mirror(x: CGFloat, width: CGFloat, layer: Int = 25, own: Bool = false, height: CGFloat = 24)
        -> MenuBarMirror.Window {
        .init(layer: layer, isOwnProcess: own, bounds: CGRect(x: x, y: 0, width: width, height: height))
    }

    @Test("同 x 同宽的 layer-25 窗口即视为有镜像")
    func matchesByGeometry() {
        let windows = [mirror(x: 100, width: 40), mirror(x: 2661, width: 80)]
        #expect(MenuBarMirror.isMirrored(windows: windows, itemFrame: itemFrame, frameIsTrustworthy: true) == true)
    }

    @Test("没有任何窗口对得上 → 没有镜像")
    func reportsMissingMirror() {
        #expect(MenuBarMirror.isMirrored(
            windows: [mirror(x: 100, width: 40)], itemFrame: itemFrame, frameIsTrustworthy: true) == false)
        #expect(MenuBarMirror.isMirrored(
            windows: [], itemFrame: itemFrame, frameIsTrustworthy: true) == false)
    }

    @Test("frame 不新鲜时信号作废，绝不判成没有镜像")
    func ignoresSignalWhenFrameStale() {
        // 这是最关键的一条：拿过期坐标比几何必然对不上，
        // 若返回 false 就会把健康的状态项误判成被拉黑，给用户弹一条假横幅。
        #expect(MenuBarMirror.isMirrored(
            windows: [mirror(x: 2661, width: 80)], itemFrame: itemFrame, frameIsTrustworthy: false) == nil)
        #expect(MenuBarMirror.isMirrored(
            windows: [], itemFrame: itemFrame, frameIsTrustworthy: false) == nil)
        #expect(MenuBarMirror.isMirrored(
            windows: [], itemFrame: nil, frameIsTrustworthy: true) == nil)
        #expect(MenuBarMirror.isMirrored(
            windows: [], itemFrame: .zero, frameIsTrustworthy: true) == nil)
    }

    @Test("别的层、自己的窗口、过高的窗口都不算镜像")
    func rejectsIrrelevantWindows() {
        // layer 0 的普通窗口恰好同 x 同宽
        #expect(MenuBarMirror.isMirrored(
            windows: [mirror(x: 2661, width: 80, layer: 0)],
            itemFrame: itemFrame, frameIsTrustworthy: true) == false)
        // 自己进程的状态项窗口本身也在 layer 25 上，不能拿它当镜像
        #expect(MenuBarMirror.isMirrored(
            windows: [mirror(x: 2661, width: 80, own: true)],
            itemFrame: itemFrame, frameIsTrustworthy: true) == false)
        // 控制中心自己的下拉面板：同 x 同宽但很高
        #expect(MenuBarMirror.isMirrored(
            windows: [mirror(x: 2661, width: 80, height: 400)],
            itemFrame: itemFrame, frameIsTrustworthy: true) == false)
    }

    @Test("容差 2 点以内算命中，超出不算")
    func respectsEdgeTolerance() {
        #expect(MenuBarMirror.isMirrored(
            windows: [mirror(x: 2663, width: 78)], itemFrame: itemFrame, frameIsTrustworthy: true) == true)
        #expect(MenuBarMirror.isMirrored(
            windows: [mirror(x: 2664, width: 80)], itemFrame: itemFrame, frameIsTrustworthy: true) == false)
    }
}
