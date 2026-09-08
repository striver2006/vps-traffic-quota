import Foundation
import Testing
@testable import VPSQuotaCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"),
        "找不到 fixture：\(name).json"
    )
    return try Data(contentsOf: url)
}

@Suite("上游数据解析")
struct ParsingTests {

    @Test("解析 Vultr 的 bandwidth 响应")
    func vultrBandwidth() throws {
        let parsed = try JSONDecoder().decode(
            VultrCollector.BandwidthResponse.self, from: fixture("vultr-bandwidth")
        )
        #expect(parsed.bandwidth.count == 4)
        let day = try #require(parsed.bandwidth["2026-09-02"])
        #expect(day.incomingBytes == 268_435_456)
        #expect(day.outgoingBytes == 3_221_225_472)
    }

    @Test("解析 Vultr 的实例列表并取出 allowed_bandwidth")
    func vultrInstances() throws {
        let parsed = try JSONDecoder().decode(
            VultrCollector.InstancesResponse.self, from: fixture("vultr-instances")
        )
        #expect(parsed.instances.count == 2)
        let first = parsed.instances[0]
        #expect(first.id == "cb676a46-66fd-4dfb-b839-443f2e6c0b60")
        #expect(first.label == "tokyo-node")
        #expect(first.allowedBandwidth == 1000)
        #expect(first.mainIP == "192.0.2.10")
    }

    @Test("解析 vnstat 的日流量并按网卡区分")
    func vnstatDays() throws {
        let parsed = try JSONDecoder().decode(
            SSHVnstatCollector.VnstatOutput.self, from: fixture("vnstat-day")
        )
        #expect(parsed.interfaces.map(\.name) == ["eth0", "lo"])

        let eth0 = try #require(parsed.interfaces.first { $0.name == "eth0" })
        let days = try #require(eth0.traffic.day)
        #expect(days.count == 4)
        #expect(days[1].date.year == 2026)
        #expect(days[1].date.month == 9)
        #expect(days[1].date.day == 1)
        #expect(days[1].rx == 2_147_483_648)
        #expect(days[1].tx == 1_073_741_824)
    }

    @Test("vnstat 的日期被拼成零填充的 YYYY-MM-DD")
    func dayStringIsZeroPadded() {
        #expect(UTCDay.string(year: 2026, month: 9, day: 3) == "2026-09-03")
        #expect(UTCDay.string(year: 2026, month: 12, day: 25) == "2026-12-25")
    }

    @Test("YYYY-MM-DD 的字典序等于时间序，SQLite 的文本比较才成立")
    func lexicographicOrderMatchesChronological() {
        let unsorted = ["2026-10-01", "2026-09-30", "2025-12-31", "2026-09-03"]
        #expect(unsorted.sorted() == ["2025-12-31", "2026-09-03", "2026-09-30", "2026-10-01"])
    }
}
