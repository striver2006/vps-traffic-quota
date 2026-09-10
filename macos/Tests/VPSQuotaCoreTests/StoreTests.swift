import Foundation
import Testing
@testable import VPSQuotaCore

@Suite("本地存储")
struct StoreTests {

    private func makeStore() throws -> (SQLiteStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vpsquota-tests-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("usage.sqlite")
        return (try SQLiteStore(path: file), dir)
    }

    @Test("写入后能按区间读回，且左闭右开")
    func upsertAndRange() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.upsert(serverId: "s1", days: [
            DailyUsage(day: "2026-08-31", rxBytes: 1, txBytes: 1),
            DailyUsage(day: "2026-09-01", rxBytes: 10, txBytes: 20),
            DailyUsage(day: "2026-09-02", rxBytes: 30, txBytes: 40),
            DailyUsage(day: "2026-10-01", rxBytes: 9, txBytes: 9),
        ])

        let rows = try await store.days(serverId: "s1", from: "2026-09-01", toExclusive: "2026-10-01")
        #expect(rows.map(\.day) == ["2026-09-01", "2026-09-02"])
        #expect(rows[0].rxBytes == 10)
        #expect(rows[1].txBytes == 40)
    }

    @Test("同一天再次写入是覆盖而非累加")
    func upsertOverwrites() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.upsert(serverId: "s1", days: [DailyUsage(day: "2026-09-01", rxBytes: 10, txBytes: 10)])
        // 当天的流量在一天之内会持续增长，第二次采集必须覆盖掉第一次的值
        try await store.upsert(serverId: "s1", days: [DailyUsage(day: "2026-09-01", rxBytes: 50, txBytes: 60)])

        let rows = try await store.days(serverId: "s1", from: "2026-09-01", toExclusive: "2026-09-02")
        #expect(rows.count == 1)
        #expect(rows[0].rxBytes == 50)
        #expect(rows[0].txBytes == 60)
    }

    @Test("不同服务器的数据互不干扰")
    func serversAreIsolated() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.upsert(serverId: "s1", days: [DailyUsage(day: "2026-09-01", rxBytes: 1, txBytes: 1)])
        try await store.upsert(serverId: "s2", days: [DailyUsage(day: "2026-09-01", rxBytes: 2, txBytes: 2)])

        let s1 = try await store.days(serverId: "s1", from: "2026-09-01", toExclusive: "2026-09-02")
        #expect(s1.count == 1)
        #expect(s1[0].rxBytes == 1)
    }

    @Test("只有成功的采集才更新最后成功时间")
    func lastSuccessIgnoresFailures() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let early = Date(timeIntervalSince1970: 1_000_000)
        let later = Date(timeIntervalSince1970: 2_000_000)

        #expect(try await store.lastSuccess(serverId: "s1") == nil)

        try await store.logFetch(serverId: "s1", at: early, ok: true, error: nil)
        try await store.logFetch(serverId: "s1", at: later, ok: false, error: "SSH 不通")

        let last = try #require(try await store.lastSuccess(serverId: "s1"))
        #expect(Int(last.timeIntervalSince1970) == Int(early.timeIntervalSince1970))
    }

    @Test("空数组写入不报错")
    func emptyUpsertIsNoop() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.upsert(serverId: "s1", days: [])
    }

    @Test("配置文件的读写往返")
    func configRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vpsquota-cfg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        #expect(!store.exists)
        // 文件不存在时返回空配置而不是抛错，首次启动才不会卡住
        #expect(try store.load().servers.isEmpty)

        let config = AppConfig(refreshIntervalMinutes: 360, servers: [
            ServerConfig(id: "a", name: "东京", provider: .vultr,
                         quotaGB: 0, meterMode: .outbound, resetDay: 1,
                         unitBase: .decimal, vultrInstanceId: "abc"),
            ServerConfig(id: "b", name: "洛杉矶", provider: .ssh,
                         quotaGB: 1000, meterMode: .sum, resetDay: 15,
                         sshHost: "1.2.3.4", sshPort: 2222, sshUser: "root",
                         sshKeyPath: "~/.ssh/id_ed25519", interface: "eth0"),
        ])
        try store.save(config)

        let loaded = try store.load()
        #expect(loaded.refreshIntervalMinutes == 360)
        #expect(loaded.servers == config.servers)
    }

    @Test("旧配置缺少后加的字段时按默认值补齐，而不是整份读不出来")
    func decodesLegacyConfig() throws {
        let json = """
        { "servers": [ { "id": "a", "name": "旧机器", "provider": "ssh", "sshHost": "1.2.3.4" } ] }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.refreshIntervalMinutes == 60)
        #expect(config.servers.count == 1)
        #expect(config.servers[0].unitBase == .binary)
        #expect(config.servers[0].meterMode == .outbound)
        #expect(config.servers[0].resetDay == 1)
        #expect(config.servers[0].quotaGB == 0)
    }
}

/// 上游元数据与错误的持久化（P5、S3）。
///
/// 这两样以前只存在内存里：应用一重启，一台一直连不上的服务器会显示成"正常"，
/// 而 quotaGB 填 0 的 Vultr 实例会显示成"配额未知"—— 直到第一轮采集跑完为止。
@Suite("元数据持久化")
struct StoreMetaTests {

    private func makeStore() throws -> (SQLiteStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vpsquota-meta-\(UUID().uuidString)", isDirectory: true)
        return (try SQLiteStore(path: dir.appendingPathComponent("usage.sqlite")), dir)
    }

    @Test("上游报告的配额写入后能读回，且是覆盖式的")
    func reportedQuotaRoundTrip() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(try await store.reportedQuota(serverId: "s1") == nil)

        try await store.setReportedQuota(serverId: "s1", quotaGB: 2000)
        #expect(try await store.reportedQuota(serverId: "s1") == 2000)

        try await store.setReportedQuota(serverId: "s1", quotaGB: 4000)
        #expect(try await store.reportedQuota(serverId: "s1") == 4000)
    }

    @Test("传 nil 表示这次没拿到，不覆盖已有值")
    func nilQuotaDoesNotOverwrite() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.setReportedQuota(serverId: "s1", quotaGB: 2000)
        try await store.setReportedQuota(serverId: "s1", quotaGB: nil)
        #expect(try await store.reportedQuota(serverId: "s1") == 2000)
    }

    @Test("最近一次采集失败时读得到错误原因")
    func lastErrorAfterFailure() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try await store.logFetch(serverId: "s1", at: t0, ok: true, error: nil)
        try await store.logFetch(serverId: "s1", at: t0 + 60, ok: false, error: "Permission denied")

        #expect(try await store.lastError(serverId: "s1") == "Permission denied")
    }

    @Test("最近一次成功时不再报旧错误")
    func lastErrorClearedBySuccess() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try await store.logFetch(serverId: "s1", at: t0, ok: false, error: "Permission denied")
        try await store.logFetch(serverId: "s1", at: t0 + 60, ok: true, error: nil)

        #expect(try await store.lastError(serverId: "s1") == nil)
    }

    @Test("从未采集过时没有错误")
    func lastErrorIsNilWhenNeverFetched() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await store.lastError(serverId: "s1") == nil)
    }
}
