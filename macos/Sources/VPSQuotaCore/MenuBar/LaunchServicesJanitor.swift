import Foundation

/// LaunchServices 陈旧注册（死记录）的检测与注销。
///
/// macOS 26 的 ControlCenter 创建状态项 host 时按 bundle id 查 LaunchServices，
/// 只要撞上一条**路径已不存在**的注册记录（重编时删掉构建产物、换输出目录、
/// 反复挂 DMG 测试都会留下），就把这个 bundle id 的状态项
/// `Moving host to blocked list` 并隐藏。清掉死记录后，下一次注册立即恢复。
///
/// 实测约束（TokenBar 项目 2026-09-14 受控实验，机制结论通用）：
/// - `lsregister -u <path>` 只认路径上真实存在的合法 bundle；路径已删除时直接失败
///   （-10814）。唯一可行的注销方式是**原位重建一个最小 stub .app → `-u` → 删掉 stub**。
/// - `lsregister -gc` 清不掉死记录；同 bundle id 在新路径重新注册（`-f`）也挤不掉它。
/// - `NSWorkspace.urlsForApplications(withBundleIdentifier:)` 会过滤掉不存在的路径，
///   拿它永远找不到死记录，只能解析 `lsregister -dump` 的全量输出。
///
/// 全部为无状态的静态函数；dump 全量输出本机约 1 秒、几十 MB，
/// 调用方应放到后台队列执行（`staleLaunchServicesPaths(bundleID:)` 可直接后台跑）。
public enum LaunchServicesJanitor {

    public static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// 跑 `lsregister -dump` 并取本 bundle id 所有注册路径里已不存在的那些。
    /// 可在后台线程跑。
    ///
    /// 返回 nil 表示**没查成**（起不来 / 被看门狗杀掉 / 退出码非 0 / 输出解不出码），
    /// 与"查成了、确实没有"的空数组严格区分——工具一失败就伪装成空数组的话，
    /// 日志里的"无死记录"就成了假阴性。看门狗防的是 dump 挂死：这条在重建路径上
    /// 被同步等待，挂死会让重建闸门永久关死。
    nonisolated public static func staleLaunchServicesPaths(bundleID: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = ["-dump"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // 全量 dump 本机 ~1 秒、几十 MB；15 秒还没跑完按挂死处理
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return staleLaunchServicesPaths(inDump: text, bundleID: bundleID) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    /// `lsregister -dump` 的纯文本解析，抽出来便于单测。
    ///
    /// 记录之间用整行 80 个 `-` 分隔；每条记录里 `identifier:` 与 `path:` 各占一行、
    /// 值前有对齐空白，path 末尾带 ` (0x…)` 序号。只认本 bundle id 且路径已不存在的记录。
    nonisolated public static func staleLaunchServicesPaths(
        inDump text: String,
        bundleID: String,
        fileExists: (String) -> Bool
    ) -> [String] {
        var stale: [String] = []
        var identifier: String?
        var path: String?

        func flush() {
            defer { identifier = nil; path = nil }
            guard identifier == bundleID, let path, !path.isEmpty, !fileExists(path) else { return }
            stale.append(path)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.count >= 20, line.allSatisfy({ $0 == "-" }) {
                flush()
            } else if line.hasPrefix("identifier:") {
                identifier = line.dropFirst("identifier:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("path:") {
                var value = line.dropFirst("path:".count).trimmingCharacters(in: .whitespaces)
                if value.hasSuffix(")"), let range = value.range(of: " (0x", options: .backwards) {
                    value = String(value[..<range.lowerBound])
                }
                path = value
            }
        }
        flush()
        return stale
    }

    /// 注销一条本 bundle id 的死记录。
    ///
    /// 快路径：路径上有真实 bundle（或记录已被别处清掉）时 `-u` 直接生效。
    /// 否则原位重建最小 stub .app → `-u` → 删掉 stub。
    /// `/Volumes/...` 这类不可写路径上的死记录会失败，由调用方如实上报留给人工处理。
    nonisolated public static func unregisterRecord(atPath path: String, bundleID: String) -> Bool {
        if runLSRegister(["-u", path]) { return true }

        let fm = FileManager.default
        // 双保险：解析时该路径确实不存在；若此刻又出现了（比如用户刚在旧路径重建应用），
        // 那已经不是死记录，绝不能动它
        guard !fm.fileExists(atPath: path) else { return false }

        let contentsDir = (path as NSString).appendingPathComponent("Contents")
        let plistPath = (contentsDir as NSString).appendingPathComponent("Info.plist")
        let macosDir = (contentsDir as NSString).appendingPathComponent("MacOS")

        // createDirectory(withIntermediateDirectories:) 会连父目录一起建；先把原本不存在
        // 的目录链记下来，注销后按 rmdir 语义逐级回收，绝不碰任何已存在的目录
        var missingAncestors: [String] = []
        var dir = (path as NSString).deletingLastPathComponent
        while !fm.fileExists(atPath: dir) {
            missingAncestors.insert(dir, at: 0)
            let parent = (dir as NSString).deletingLastPathComponent
            guard parent != dir else { break }
            dir = parent
        }

        guard (try? fm.createDirectory(atPath: macosDir, withIntermediateDirectories: true)) != nil,
              fm.createFile(atPath: plistPath, contents: stubInfoPlist(bundleID: bundleID)),
              fm.createFile(atPath: (macosDir as NSString).appendingPathComponent("LSTombstone"), contents: nil)
        else { return false }

        defer {
            try? fm.removeItem(atPath: path)
            for ancestor in missingAncestors.reversed() {
                _ = Darwin.rmdir(ancestor) // 只删空目录，中途有别的文件落进来就留着
            }
        }
        return runLSRegister(["-u", path])
    }

    /// 注销死记录用的最小 stub Info.plist。lsregister 只要求路径上能扫描出一个合法
    /// bundle；CFBundleIdentifier 必须与要注销的记录一致，否则 `-u` 匹配不上。
    nonisolated public static func stubInfoPlist(bundleID: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(bundleID)</string>
            <key>CFBundleName</key>
            <string>LSTombstone</string>
            <key>CFBundleExecutable</key>
            <string>LSTombstone</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    nonisolated private static func runLSRegister(_ arguments: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: lsregisterPath) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
