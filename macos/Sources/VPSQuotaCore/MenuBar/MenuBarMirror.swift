import Foundation
import CoreGraphics

/// 「控制中心有没有为这个状态项渲染菜单栏镜像」的匹配逻辑。
///
/// macOS 26：每个真正显示出来的状态项，在 layer-25 层都有一个 onscreen 的控制中心窗口，
/// 与应用自己那个离屏的状态项窗口同 x 同宽。被 ControlCenter 拉黑的状态项没有这条镜像
/// —— 这是唯一能观测到「被拉黑」的信号，几何判定只是辅助（被拉黑的状态项 frame
/// 也可能停在正常位置）。
///
/// 刻意**不**按 `kCGWindowName` 匹配：读别的进程的窗口名要屏幕录制权限，
/// 一个流量监控工具不该为一个诊断信号索取那种权限。代价是匹配只能靠几何，
/// 所以 frame 不新鲜时必须返回 nil 让信号作废，而不是误判成掉线。
///
/// 纯函数，窗口列表由调用方采样后传入，便于单测。
public enum MenuBarMirror {
    /// 控制中心菜单栏镜像所在的窗口层
    public static let hostLayer = 25
    /// 只认菜单栏那一排，排除控制中心自己的下拉面板
    public static let maxHeight: CGFloat = 40
    /// 同 x 同宽的容差
    public static let edgeTolerance: CGFloat = 2

    /// 一个 CGWindowList 条目里我们关心的字段
    public struct Window: Equatable {
        public let layer: Int
        public let isOwnProcess: Bool
        public let bounds: CGRect

        public init(layer: Int, isOwnProcess: Bool, bounds: CGRect) {
            self.layer = layer
            self.isOwnProcess = isOwnProcess
            self.bounds = bounds
        }
    }

    /// - Parameters:
    ///   - itemFrame: 状态项按钮窗口的 frame；nil 表示拿不到
    ///   - frameIsTrustworthy: `itemFrame` 此刻可不可信。托管窗口的坐标会停在旧值不更新
    ///     （显示器睡眠/重连后尤甚），拿过期坐标去比几何必然对不上，会把健康的状态项
    ///     误判成 notMirrored 进而误报「被系统拉黑」。
    /// - Returns: nil 表示**这次判不了**，调用方必须忽略该信号，绝不当成掉线。
    public static func isMirrored(
        windows: [Window],
        itemFrame: CGRect?,
        frameIsTrustworthy: Bool
    ) -> Bool? {
        guard frameIsTrustworthy, let frame = itemFrame, frame.width > 0 else { return nil }

        for window in windows {
            guard window.layer == hostLayer,
                  !window.isOwnProcess,
                  window.bounds.height <= maxHeight
            else { continue }
            if abs(window.bounds.minX - frame.minX) <= edgeTolerance,
               abs(window.bounds.width - frame.width) <= edgeTolerance {
                return true
            }
        }
        return false
    }
}
