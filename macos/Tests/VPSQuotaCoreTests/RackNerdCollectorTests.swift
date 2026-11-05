import Foundation
import Testing
@testable import VPSQuotaCore

@Suite("RackNerd 采集")
struct RackNerdCollectorTests {

    @Test("首次观测：没有快照，整个计数器都记到当天")
    func firstObservation() {
        let (days, snapshot) = RackNerdCollector.derive(
            today: "2026-11-01", counter: 50_000_000, previous: nil)

        #expect(days == [DailyUsage(day: "2026-11-01", rxBytes: 0, txBytes: 50_000_000)])
        #expect(snapshot == RackNerdCollector.Snapshot(
            dayKey: "2026-11-01", dayStartCounter: 0, counter: 50_000_000))
    }

    @Test("同一天内多次观测是绝对重算：当天用量 = 计数器 − 当日基线，天然幂等")
    func sameDayIsAbsoluteRecompute() {
        let prev = RackNerdCollector.Snapshot(
            dayKey: "2026-11-01", dayStartCounter: 10_000_000, counter: 20_000_000)

        let first = RackNerdCollector.derive(today: "2026-11-01", counter: 35_000_000, previous: prev)
        #expect(first.days == [DailyUsage(day: "2026-11-01", rxBytes: 0, txBytes: 25_000_000)])
        #expect(first.snapshot.dayStartCounter == 10_000_000)

        let second = RackNerdCollector.derive(today: "2026-11-01", counter: 40_000_000, previous: first.snapshot)
        #expect(second.days == [DailyUsage(day: "2026-11-01", rxBytes: 0, txBytes: 30_000_000)])
    }

    @Test("跨天：昨天最后一次观测值成为今天的基线，隔夜的增量记到今天")
    func dayRollover() {
        let prev = RackNerdCollector.Snapshot(
            dayKey: "2026-11-01", dayStartCounter: 10_000_000, counter: 20_000_000)

        let (days, snapshot) = RackNerdCollector.derive(
            today: "2026-11-02", counter: 26_000_000, previous: prev)

        #expect(days == [DailyUsage(day: "2026-11-02", rxBytes: 0, txBytes: 6_000_000)])
        #expect(snapshot.dayStartCounter == 20_000_000)
    }

    @Test("计数器回落 → 换账期，基线归零，新计数器整体属于新账期")
    func counterDropMeansNewCycle() {
        let prev = RackNerdCollector.Snapshot(
            dayKey: "2026-11-01", dayStartCounter: 10_000_000, counter: 90_000_000)

        let (days, snapshot) = RackNerdCollector.derive(
            today: "2026-11-01", counter: 50_000, previous: prev)

        #expect(days == [DailyUsage(day: "2026-11-01", rxBytes: 0, txBytes: 50_000)])
        #expect(snapshot.dayStartCounter == 0)
    }

    @Test("计数器没动：当天写 0，不报错也不累加")
    func idleCounter() {
        let prev = RackNerdCollector.Snapshot(
            dayKey: "2026-11-01", dayStartCounter: 20_000_000, counter: 20_000_000)

        let (days, snapshot) = RackNerdCollector.derive(
            today: "2026-11-01", counter: 20_000_000, previous: prev)

        #expect(days == [DailyUsage(day: "2026-11-01", rxBytes: 0, txBytes: 0)])
        #expect(snapshot.counter == 20_000_000)
    }

    @Test("快照按服务器 ID 独立落盘")
    func stateStorePersistence() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = RackNerdStateStore(directory: tmp)
        let s = RackNerdCollector.Snapshot(dayKey: "2026-11-01", dayStartCounter: 100, counter: 500)
        try store.save(serverId: "rn-1", snapshot: s)

        let loaded = store.load(serverId: "rn-1")
        #expect(loaded == s)
        #expect(store.load(serverId: "rn-2") == nil)
    }

    @Test("403 + Cf-Mitigated 头：识别为 Cloudflare 质询拦截，给出可行动提示而不是透出 HTML")
    func detectsCloudflareChallengeByHeader() {
        let error = RackNerdCollector.buildHttpError(
            status: 403, cfMitigated: "challenge", body: "<html>质询页正文……</html>")

        #expect(error.errorDescription?.contains("Cloudflare 人机验证拦截（HTTP 403）") == true)
        #expect(error.errorDescription?.contains("API Key 与 API Hash 并没有问题") == true)
        #expect(error.errorDescription?.contains("<html>") != true)
    }

    @Test("403 + Just a moment 页面（代理剥掉响应头时按正文兜底识别）")
    func detectsCloudflareChallengeByBody() {
        let error = RackNerdCollector.buildHttpError(
            status: 403, cfMitigated: nil,
            body: "<!DOCTYPE html><html><head><title>Just a moment...</title></head></html>")

        #expect(error.errorDescription?.contains("Cloudflare 人机验证拦截") == true)
        #expect(error.errorDescription?.contains("<!DOCTYPE html>") != true)
    }

    @Test("503 全站攻击模式质询页同样识别")
    func detectsUnderAttackModeChallenge() {
        let error = RackNerdCollector.buildHttpError(
            status: 503, cfMitigated: nil,
            body: "<html>Checking your browser before accessing the site.</html>")

        #expect(error.errorDescription?.contains("Cloudflare 人机验证拦截（HTTP 503）") == true)
    }

    @Test("普通 403：维持原有 HTTP 错误格式，保留上游报错正文")
    func ordinary403KeepsHttpFormat() {
        let error = RackNerdCollector.buildHttpError(
            status: 403, cfMitigated: nil,
            body: #"{"status":"error","statusmsg":"invalid key"}"#)

        #expect(error.errorDescription?.hasPrefix("HTTP 403") == true)
        #expect(error.errorDescription?.contains("invalid key") == true)
    }
}
