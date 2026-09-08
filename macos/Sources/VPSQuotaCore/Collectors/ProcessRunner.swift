import Foundation

/// 一次外部命令执行的结果。
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

/// 线程安全的输出累加器。
///
/// `readabilityHandler` 在后台队列被反复调用，必须加锁；
/// 同时要分别读 stdout 和 stderr，不能等一个读完再读另一个 ——
/// 管道缓冲区（约 64KB）填满后子进程会阻塞在 write 上，造成死锁。
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// 只允许被置位一次的布尔标记。
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
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

    /// 执行外部命令并等待结束。
    ///
    /// - Parameter timeout: 硬超时。SSH 的 `ConnectTimeout` 只覆盖连接阶段，
    ///   连上之后卡住（例如对端负载极高）仍可能无限等待，所以外面还要有一层。
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

        let outBuf = OutputBuffer()
        let errBuf = OutputBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { outBuf.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { errBuf.append(chunk) }
        }

        let didTimeOut = Flag()

        // 进程结束（正常退出或被超时逻辑 terminate）只会触发一次 terminationHandler，
        // 因此续体也只会被恢复一次。必须在 run() 之前挂上。
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
            do {
                try process.run()
            } catch {
                // 启动失败时 terminationHandler 不会触发，这里自行恢复并留下痕迹。
                didTimeOut.set()
                errBuf.append(Data("__launch_failed__: \(error.localizedDescription)".utf8))
                process.terminationHandler = nil
                cont.resume()
                return
            }

            // 超时看门狗：不阻塞任何线程，到点后 terminate，仍由 terminationHandler 收尾。
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if process.isRunning {
                    didTimeOut.set()
                    process.terminate()
                }
            }
        }

        // 关闭 handler 后把管道里的残余数据读干净，避免丢掉最后一截输出。
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outBuf.append(outPipe.fileHandleForReading.availableData)
        errBuf.append(errPipe.fileHandleForReading.availableData)

        let stderrText = errBuf.string
        if stderrText.hasPrefix("__launch_failed__: ") {
            throw RunError.launchFailed(
                String(stderrText.dropFirst("__launch_failed__: ".count))
            )
        }
        if didTimeOut.isSet {
            throw RunError.timedOut(seconds: timeout)
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: outBuf.string,
            stderr: stderrText
        )
    }
}
