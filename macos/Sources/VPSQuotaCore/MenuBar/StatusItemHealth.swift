import Foundation
import CoreGraphics

/// 状态项"还在不在菜单栏上"的判定，以及判定为掉线后的重建退避策略。
///
/// 起因（macOS 26 实测，机制结论移植自 TokenBar 项目 2026-09-14 的受控实验，
/// 见 docs/TROUBLESHOOTING_菜单栏图标不显示.md）：状态项对象活着、frame 完全正常，
/// 但 ControlCenter 没有为它渲染菜单栏镜像——图标就是看不见。
/// 根因不在应用代码：ControlCenter 按 bundle id 查 LaunchServices，
/// 撞上一条路径已不存在的陈旧注册记录（重编删产物、换输出目录都会留下）就把
/// 这个 bundle id 的状态项 `Moving host to blocked list` 并隐藏，
/// 且拉黑是跨进程重启的粘性会话态。所以最可靠的健康信号是
/// **控制中心有没有为它画镜像**（layer-25、onscreen、同 x 同宽）；
/// 几何判定只是辅助——被 block 的状态项 frame 也可能停在正常位置。
///
/// 全部为纯函数，几何由调用方采样后传入，便于单测。
public enum StatusItemHealth {

    /// 一块屏幕的几何，避免纯函数依赖 NSScreen
    public struct ScreenGeometry: Equatable {
        public let frame: CGRect
        public let visibleFrame: CGRect

        public init(frame: CGRect, visibleFrame: CGRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    /// 由 StatusItemController 从 AppKit 采样得到的状态项快照
    public struct Snapshot: Equatable {
        public let hasItem: Bool
        public let hasButton: Bool
        /// `NSStatusItem.isVisible`
        public let isVisible: Bool
        public let buttonWidth: CGFloat
        /// `button.window?.frame`（AppKit 屏幕坐标）；window 为 nil 时传 nil
        public let windowFrame: CGRect?
        /// `button.window?.windowNumber`；≤ 0 表示窗口从未被窗口服务器接管
        public let windowNumber: Int?
        /// 按窗口号在 CGWindowList 里能否查到；**无法查询时传 nil，该信号被忽略**。
        /// macOS 26 托管状态项的 windowNumber 是 2^32 这类占位值，实际上恒为 nil。
        public let registeredInWindowServer: Bool?
        /// 控制中心是否为它渲染了菜单栏镜像（layer-25、onscreen、与 windowFrame 同 x 同宽）。
        /// 这是 macOS 26 上最可靠的信号；**无法查询时传 nil，该信号被忽略**。
        public let mirroredByMenuBarHost: Bool?
        public let screens: [ScreenGeometry]

        public init(
            hasItem: Bool,
            hasButton: Bool,
            isVisible: Bool,
            buttonWidth: CGFloat,
            windowFrame: CGRect?,
            windowNumber: Int?,
            registeredInWindowServer: Bool?,
            mirroredByMenuBarHost: Bool? = nil,
            screens: [ScreenGeometry]
        ) {
            self.hasItem = hasItem
            self.hasButton = hasButton
            self.isVisible = isVisible
            self.buttonWidth = buttonWidth
            self.windowFrame = windowFrame
            self.windowNumber = windowNumber
            self.registeredInWindowServer = registeredInWindowServer
            self.mirroredByMenuBarHost = mirroredByMenuBarHost
            self.screens = screens
        }
    }

    public enum Reason: String, Equatable {
        case noItem
        case noButton
        case noWindow
        case zeroWindowNumber
        case zeroWindowSize
        case zeroButtonWidth
        case notRegistered
        case offMenuBar
        /// 控制中心没有为它渲染镜像 —— 典型就是被 blocked list 隐藏
        case notMirrored
    }

    public enum Verdict: Equatable {
        case healthy
        /// `isVisible == false`：用户 Cmd 拖走或历史持久化状态。**不重建** —— 重建会覆盖用户意图。
        case userHidden
        /// 掉线，需要重建
        case detached(Reason)
        /// 无屏幕 / 正在重配置：本轮跳过，且不计入连续掉线计数
        case indeterminate

        public var isDetached: Bool {
            if case .detached = self { return true }
            return false
        }

        public var logDescription: String {
            switch self {
            case .healthy: return "healthy"
            case .userHidden: return "userHidden"
            case .indeterminate: return "indeterminate"
            case .detached(let reason): return "detached(\(reason.rawValue))"
            }
        }
    }

    /// 判定顺序即优先级，不要调整：
    /// `isVisible` 必须排在所有几何判定之前，否则用户主动隐藏会被当成故障反复重建。
    public static func evaluate(_ snapshot: Snapshot) -> Verdict {
        // 熄屏 / 显示器重配置中途，几何不可信，绝不在这时重建
        guard !snapshot.screens.isEmpty else { return .indeterminate }

        guard snapshot.hasItem else { return .detached(.noItem) }
        guard snapshot.hasButton else { return .detached(.noButton) }

        guard snapshot.isVisible else { return .userHidden }

        guard let frame = snapshot.windowFrame else { return .detached(.noWindow) }
        guard (snapshot.windowNumber ?? 0) > 0 else { return .detached(.zeroWindowNumber) }
        guard frame.width > 0, frame.height > 0 else { return .detached(.zeroWindowSize) }
        guard snapshot.buttonWidth > 0 else { return .detached(.zeroButtonWidth) }

        // 几何判定在前：它只依赖 AppKit 自己的数字，比窗口服务器那条信号可靠。
        let onMenuBar = snapshot.screens.contains { screen in
            MenuBarBand.isInMenuBarBand(
                frame,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        guard onMenuBar else { return .detached(.offMenuBar) }

        // 几何看着正常，但控制中心没为它画镜像 —— 图标一样是看不见的。
        // nil = 查不了（无权限 / API 变化），忽略该信号，绝不因为查不到就判掉线。
        if snapshot.mirroredByMenuBarHost == false { return .detached(.notMirrored) }
        if snapshot.registeredInWindowServer == false { return .detached(.notRegistered) }

        return .healthy
    }

    /// 重建退避。重建会让图标闪一下、并可能改变它在菜单栏里的排序，
    /// 所以要连续确认、指数退避、总次数封顶，宁可晚修也不要抖动。
    public struct RebuildPolicy: Equatable {
        /// 连续几次判定掉线才真正动手
        public var confirmations: Int
        /// 单次运行的重建预算
        public var maxAttempts: Int
        /// 退避基数：30 / 60 / 120 / 240 …
        public var baseInterval: TimeInterval
        public var maxInterval: TimeInterval
        /// 连续健康这么久之后，重建预算清零
        public var stableResetWindow: TimeInterval

        public init(
            confirmations: Int = 2,
            maxAttempts: Int = 5,
            baseInterval: TimeInterval = 30,
            maxInterval: TimeInterval = 900,
            stableResetWindow: TimeInterval = 600
        ) {
            self.confirmations = confirmations
            self.maxAttempts = maxAttempts
            self.baseInterval = baseInterval
            self.maxInterval = maxInterval
            self.stableResetWindow = stableResetWindow
        }

        public enum Decision: Equatable {
            /// 还没到确认次数，或还在退避窗口内；调用方自行与探测间隔取 max
            case wait(TimeInterval)
            case rebuild
            /// 预算最后一次：先清掉 autosave 的位置/可见性键再重建。
            /// 没有这一档的话，持久化位置被写坏时带 autosaveName 重建会一直把坏状态还原回来。
            case resetAutosaveThenRebuild
            case giveUp
        }

        public func decide(
            verdict: Verdict,
            consecutiveDetached: Int,
            attempts: Int,
            now: Date,
            lastRebuildAt: Date?
        ) -> Decision {
            guard verdict.isDetached else { return .wait(0) }
            guard consecutiveDetached >= confirmations else { return .wait(0) }
            guard attempts < maxAttempts else { return .giveUp }

            if attempts > 0, let last = lastRebuildAt {
                let window = min(baseInterval * pow(2, Double(attempts - 1)), maxInterval)
                let elapsed = now.timeIntervalSince(last)
                if elapsed < window {
                    return .wait(window - elapsed)
                }
            }

            return attempts == maxAttempts - 1 ? .resetAutosaveThenRebuild : .rebuild
        }

        /// 连续健康够久 → 把重建预算还回去
        public func shouldResetAttempts(now: Date, healthySince: Date?) -> Bool {
            guard let healthySince else { return false }
            return now.timeIntervalSince(healthySince) >= stableResetWindow
        }
    }
}

/// 菜单栏带几何：一个矩形是否落在某块屏幕的菜单栏区域里。
///
/// 单独成 enum 是因为健康判定和锚点兜底用的是同一份几何定义；
/// 实测 macOS 26：健康状态项窗口的 maxY 正好贴齐屏幕顶边，
/// 但窗口高度未必等于带高，所以下边界要留松弛量；
/// 上边界与左右边界只留浮点容差——故障态正是从这三边越出去的。
public enum MenuBarBand {
    /// 菜单栏隐藏（全屏 / 自动隐藏）时算不出高度，用这个兜底
    public static let defaultMenuBarHeight: CGFloat = 24
    /// 菜单栏带下边界的松弛量
    public static let bottomSlack: CGFloat = 8
    /// 上边界与左右边界的浮点容差。留大了就会把越界的故障态放过去。
    public static let edgeEpsilon: CGFloat = 0.5

    /// 菜单栏高度 = 屏幕顶边 − 可见区顶边；≤0 说明菜单栏隐藏，用默认值
    static func menuBarHeight(screenFrame: CGRect, visibleFrame: CGRect, fallback: CGFloat) -> CGFloat {
        let height = screenFrame.maxY - visibleFrame.maxY
        return height <= 0 ? fallback : height
    }

    public static func isInMenuBarBand(
        _ rect: CGRect,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        defaultMenuBarHeight: CGFloat = defaultMenuBarHeight,
        bottomSlack: CGFloat = bottomSlack
    ) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        guard rect.maxY <= screenFrame.maxY + edgeEpsilon,
              rect.minX >= screenFrame.minX - edgeEpsilon,
              rect.maxX <= screenFrame.maxX + edgeEpsilon else { return false }
        let barHeight = menuBarHeight(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            fallback: defaultMenuBarHeight
        )
        return rect.maxY >= screenFrame.maxY - barHeight - bottomSlack
    }
}
