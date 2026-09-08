import Foundation

/// UTC 自然日的字符串工具。
///
/// 全程用 `YYYY-MM-DD` 字符串而不是 `Date` 作为日粒度的键，有两个实际好处：
/// 1. 该格式的字典序等于时间序，SQLite 里 `WHERE day >= ? AND day < ?` 直接可用，无需日期函数；
/// 2. 避开时区在存储层的反复转换 —— 转换只发生在采集边界上，一次性做完。
public enum UTCDay {
    /// UTC 日历，所有日期运算的基准。
    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)!
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    /// 解析 `YYYY-MM-DD`，返回该 UTC 日的零点。格式不合法时返回 nil。
    public static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }

    public static func string(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 把任意时刻截断到所在 UTC 日的零点。
    public static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }
}
