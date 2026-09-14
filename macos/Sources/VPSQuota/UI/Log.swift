import Foundation
import os

/// 全项目统一的日志出口。
///
/// 级别按 os_log 的落盘规则挑选，不是随手写的：
/// - `.notice` / `.error` 会持久化到系统日志，事后能用 `log show` 回溯；
/// - `.info` / `.debug` 只驻内存缓冲，必须 `log stream` 现场盯着才看得到。
/// 因此"用户过几天来报障、要能倒查"的事件（状态项健康判定、死记录清理）
/// 一律 notice/error；高频细节才用 info/debug。
///
/// 排查命令：
///     command log stream --predicate 'subsystem == "io.vpsquota.VPSTrafficQuota"' --level debug --style compact
enum Log {
    static let subsystem = "io.vpsquota.VPSTrafficQuota"

    /// 菜单栏状态项生命周期：安装、健康判定、重建、LaunchServices 死记录清理
    static let menubar = Logger(subsystem: subsystem, category: "menubar")
}
