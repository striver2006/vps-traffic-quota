import Foundation
import Testing
@testable import VPSQuotaCore

/// 外部命令执行。这一层的坑（管道死锁、收尾竞态、取消不生效、SIGTERM 被忽略）
/// 都是间歇性的，靠手工验证碰不到，必须用测试钉住。
@Suite("外部命令执行")
struct ProcessRunnerTests {

    private let shell = URL(fileURLWithPath: "/bin/sh")

    @Test("正常退出时拿到 stdout 与退出码")
    func capturesStdout() async throws {
        let result = try await ProcessRunner.run(
            executable: shell, arguments: ["-c", "printf 'hello'"], timeout: 10
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello")
        #expect(result.stderr.isEmpty)
    }

    @Test("非零退出码与 stderr 一并带出")
    func capturesStderrAndExitCode() async throws {
        let result = try await ProcessRunner.run(
            executable: shell, arguments: ["-c", "printf 'boom' >&2; exit 3"], timeout: 10
        )
        #expect(result.exitCode == 3)
        #expect(result.stderr == "boom")
    }

    /// 管道缓冲区大约 64KB。一次性吐远超这个量的数据，
    /// 只要读取端有半点串行化就会死锁在子进程的 write 上。
    @Test("输出远超管道缓冲区时不死锁，且一个字节都不少")
    func handlesLargeOutput() async throws {
        let count = 400_000
        let result = try await ProcessRunner.run(
            executable: shell,
            arguments: ["-c", "yes x | head -c \(count)"],
            timeout: 30
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == count)
    }

    /// 两个管道同时大量输出。收尾时若不等两边都读到 EOF，
    /// 就会拿到被截断或次序错乱的内容 —— 那正是"vnstat 输出解析失败"的来源。
    @Test("stdout 与 stderr 同时大量输出，两边都完整")
    func handlesBothStreamsAtOnce() async throws {
        let count = 200_000
        let result = try await ProcessRunner.run(
            executable: shell,
            arguments: ["-c", "yes o | head -c \(count) & yes e | head -c \(count) >&2; wait"],
            timeout: 30
        )
        #expect(result.stdout.count == count)
        #expect(result.stderr.count == count)
    }

    @Test("超时会终止进程并报超时")
    func timesOut() async throws {
        let started = Date()
        await #expect(throws: ProcessRunner.RunError.self) {
            _ = try await ProcessRunner.run(
                executable: shell, arguments: ["-c", "sleep 30"], timeout: 1
            )
        }
        // 真的被杀掉了，而不是等满 30 秒
        #expect(Date().timeIntervalSince(started) < 10)
    }

    /// 忽略 SIGTERM 的进程必须被 SIGKILL 收掉。
    /// 只发 SIGTERM 的话，await 会永久挂起，整个应用的采集就此卡死。
    @Test("忽略 SIGTERM 的进程也会被强制结束")
    func escalatesToSigkill() async throws {
        let started = Date()
        await #expect(throws: ProcessRunner.RunError.self) {
            _ = try await ProcessRunner.run(
                executable: shell,
                arguments: ["-c", "trap '' TERM; sleep 30"],
                timeout: 1
            )
        }
        #expect(Date().timeIntervalSince(started) < 15)
    }

    /// 取消一个没人再等的采集时，ssh 不该继续跑满 45 秒超时。
    @Test("外层任务取消时立刻收摊")
    func respondsToCancellation() async throws {
        let task = Task {
            try await ProcessRunner.run(
                executable: shell, arguments: ["-c", "sleep 30"], timeout: 60
            )
        }
        // 给它一点时间真正起来
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        let started = Date()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("可执行文件不存在时报启动失败，而不是当成命令执行失败")
    func reportsLaunchFailure() async throws {
        await #expect(throws: ProcessRunner.RunError.self) {
            _ = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/nonexistent/definitely-not-here"),
                arguments: [],
                timeout: 5
            )
        }
    }
}
