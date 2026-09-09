import Foundation

/// 面向展示的数值格式化。
public enum ByteFormat {

    /// 把 GB 数格式化成人读字符串：小于 1 GB 用 MB，大于等于 1024 GB 用 TB。
    public static func gb(_ value: Double) -> String {
        if value < 1 {
            return String(format: "%.0f MB", value * 1024)
        }
        if value >= 1024 {
            return String(format: "%.2f TB", value / 1024)
        }
        return String(format: value >= 100 ? "%.0f GB" : "%.1f GB", value)
    }

    /// 菜单栏专用的紧凑写法：换算规则与 `gb(_:)` 完全一致，
    /// 只是单位缩成一个字母、不留空格 —— `1.94T` 比 `1.94 TB` 省两个字符，
    /// 菜单栏本来就挤，能省则省。
    public static func compact(_ value: Double) -> String {
        if value < 1 {
            return String(format: "%.0fM", value * 1024)
        }
        if value >= 1024 {
            return String(format: "%.2fT", value / 1024)
        }
        return String(format: value >= 100 ? "%.0fG" : "%.1fG", value)
    }

    /// 百分比，保留整数位。
    public static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    /// 相对时间，用于"上次刷新于 …"。
    public static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }
}
