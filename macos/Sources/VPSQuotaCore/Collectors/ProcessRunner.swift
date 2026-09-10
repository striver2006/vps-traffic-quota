import Foundation

/// 一次外部命令执行的结果。
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum ProcessRunner {

    public enum RunError: LocalizedError {
        case launchFailed(String)
        case timedOut(seconds: Double)

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let m): return "无法启动进程：\(m)"
            case .timedOut(let s): return "命令执行超时（\(Int(s)) 秒）"
            }
        }
    }

    /// 进程被要求停下之后，等它自己退出的宽限时间。超过就上 SIGKILL。
    private static let terminationGrace: Duration = .seconds(3)

    /// 进程已退出、但管道迟迟不给 EOF 时的兜底等待。
    ///
    /// 正常情况下子进程一死，管道立刻 EOF。但如果它派生过孙子进程并把管道继承了下去，
    /// EOF 可能永远不来 —— 那样就会永久挂起，界面上表现为"正在采集…"再也不结束。
    private static let drainGrace: Duration = .seconds(2)

    /// 一次执行的全部可变状态。
    ///
    /// 三处会并发触碰它：两个管道各自的 `readabilityHandler`（在后台队列上被反复调用）、
    /// `terminationHandler`、以及超时/取消的看门狗。用同一把锁串起来，
    /// 并保证续体恰好被恢复一次。
    private final class Run: @unchecked Sendable {
        enum Outcome {
            case normal
            case timedOut
            case cancelled
        }

        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrData = Data()
        private var exitCode: Int32 = 0
        private var stdoutAtEOF = false
        private var stderrAtEOF = false
        private var hasExited = false
        private var isFinished = false
        private var outcome: Outcome = .normal

        /// 续体只在这里被恢复，且只恢复一次。
        private var resume: ((Result<ProcessResult, Error>) -> Void)?

        init(resume: @escaping (Result<ProcessResult, Error>) -> Void) {
            self.resume = resume
        }

        func append(stdout chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if chunk.isEmpty { stdoutAtEOF = true } else { stdoutData.append(chunk) }
            finishIfReadyLocked()
        }

        func append(stderr chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if chunk.isEmpty { stderrAtEOF = true } else { stderrData.append(chunk) }
            finishIfReadyLocked()
        }

        func markExited(code: Int32) {
            lock.lock(); defer { lock.unlock() }
            hasExited = true
            exitCode = code
            finishIfReadyLocked()
        }

        /// 标记本次执行的结局。返回 false 表示已经收尾过了，调用方不必再动手。
        @discardableResult
        func mark(_ value: Outcome) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !isFinished else { return false }
            // 取消优先于超时：两者同时发生时，用户看到的应该是"取消了"而不是"超时了"。
            if outcome == .normal || value == .cancelled { outcome = value }
            return true
        }

        /// 进程死了但管道不给 EOF 时的兜底：拿现有数据收尾。
        func finishRegardless() {
            lock.lock(); defer { lock.unlock() }
            stdoutAtEOF = true
            stderrAtEOF = true
            finishIfReadyLocked()
        }

        func failLaunch(_ message: String) {
            lock.lock(); defer { lock.unlock() }
            guard let resume, !isFinished else { return }
            isFinished = true
            self.resume = nil
            resume(.failure(RunError.launchFailed(message)))
        }

        var isDone: Bool {
            lock.lock(); defer { lock.unlock() }
            return isFinished
        }

        /// 收尾条件：进程已退出**且**两个管道都读到了 EOF。
        ///
        /// 只等 `terminationHandler` 是不够的：它触发时管道里可能还有没读完的数据，
        /// 而在另一个队列上仍在执行的 `readabilityHandler` 会和收尾代码同时读同一个 fd ——
        /// 数据不会损坏，但顺序会乱，表现为间歇性的"vnstat 输出解析失败"。
        private func finishIfReadyLocked() {
            guard let resume, !isFinished, hasExited, stdoutAtEOF, stderrAtEOF else { return }
            isFinished = true
            self.resume = nil

            let result: Result<ProcessResult, Error>
            switch outcome {
            case .cancelled:
                result = .failure(CancellationError())
            case .timedOut:
                result = .failure(RunError.timedOut(seconds: timeoutSeconds))
            case .normal:
                result = .success(ProcessResult(
                    exitCode: exitCode,
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? ""
                ))
            }
            resume(result)
        }

        /// 仅用于拼超时文案。
        var timeoutSeconds: Double = 0
    }

    /// 执行外部命令并等待结束。
    ///
    /// - Parameter timeout: 硬超时。SSH 的 `ConnectTimeout` 只覆盖连接阶段，
    ///   连上之后卡住（例如对端负载极高）仍可能无限等待，所以外面还要有一层。
    ///
    /// 响应 `Task` 取消：外层任务被取消时会把子进程停掉并抛 `CancellationError`，
    /// 而不是让一个没人等的 ssh 继续跑满超时。
    public static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 60
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // 明确切断标准输入：SSH 若因故想交互式提问（要密码、确认 host key），
        // 应当立刻失败并报错，而不是挂在那里等一个永远不会来的输入。
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let run = Run { continuation.resume(with: $0) }
                run.timeoutSeconds = timeout
                box.attach(run)

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    run.append(stdout: handle.availableData)
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    run.append(stderr: handle.availableData)
                }

                process.terminationHandler = { finished in
                    // handler 置 nil 之后仍在执行中的那一次调用也要能跑完，
                    // 所以清理放在收尾判定之后由 Run 自己决定时机。
                    run.markExited(code: finished.terminationStatus)

                    // 管道迟迟不给 EOF 时的兜底，避免永久挂起。
                    Task {
                        try? await Task.sleep(for: drainGrace)
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        run.finishRegardless()
                    }
                }

                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    run.failLaunch(error.localizedDescription)
                    return
                }

                // 超时看门狗。进程正常结束后这个任务会自己退出，
                // 不会像以前那样无论如何都空转满一整个 timeout。
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !run.isDone else { return }
                    if run.mark(.timedOut) { box.stop() }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// 把 `Process` 包起来交给取消回调用。
    ///
    /// `Process` 不是 `Sendable`，而 `onCancel` 可能在任意线程上跑；
    /// 这里只暴露"停下它"这一个动作，并保证 SIGTERM 之后一定会有 SIGKILL 兜底。
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var run: Run?
        private var stopping = false

        init(_ process: Process) {
            self.process = process
        }

        func attach(_ run: Run) {
            lock.lock(); defer { lock.unlock() }
            self.run = run
        }

        func cancel() {
            lock.lock()
            let target = run
            lock.unlock()
            guard target?.mark(.cancelled) ?? true else { return }
            stop()
        }

        /// 先礼后兵：SIGTERM 之后给一点宽限，还不退就 SIGKILL。
        /// 只发 SIGTERM 是不够的 —— 对方忽略它的话，`await` 会永久挂起，
        /// 整个应用的采集就此卡死。
        func stop() {
            lock.lock()
            guard !stopping else { return lock.unlock() }
            stopping = true
            let isRunning = process.isRunning
            let pid = process.processIdentifier
            lock.unlock()

            guard isRunning else { return }
            process.terminate()

            Task {
                try? await Task.sleep(for: terminationGrace)
                guard self.stillRunning else { return }
                kill(pid, SIGKILL)
            }
        }

        private var stillRunning: Bool {
            lock.lock(); defer { lock.unlock() }
            return process.isRunning
        }
    }
}
