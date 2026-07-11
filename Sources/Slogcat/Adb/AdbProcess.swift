import Foundation

/// Resolves the `adb` executable path:
///   user override (UserDefaults) → `which adb` (PATH) → common SDK locations → nil (env fallback).
enum AdbLocator {
    static let userPathKey = "adbPath"

    static var userPath: String? {
        get { UserDefaults.standard.string(forKey: userPathKey) }
        set { UserDefaults.standard.set(newValue, forKey: userPathKey) }
    }

    /// Concrete path if found, else nil (caller falls back to `/usr/bin/env adb`).
    static func resolvedPath() -> String? {
        if let user = userPath, !user.isEmpty,
           FileManager.default.isExecutableFile(atPath: user) {
            return user
        }
        if let p = whichAdb(), FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "\(home)/Android/Sdk/platform-tools/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
            "/opt/homebrew/opt/android-platform-tools/bin/adb"
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    // MARK: `which adb` (cached, runs once)

    /// `String??`: nil = not yet probed; .some(.some(path)) = found; .some(nil) = probed, not found.
    private static var whichCache: String?? = nil
    private static let whichLock = NSLock()

    /// Returns adb's path from `which adb` (PATH lookup), cached after the first call.
    private static func whichAdb() -> String? {
        whichLock.lock()
        let cached = whichCache
        whichLock.unlock()
        if let c = cached { return c }                  // already probed (path or nil)
        let found = runWhich()
        whichLock.lock()
        whichCache = .some(found)
        whichLock.unlock()
        return found
    }

    private static func runWhich() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "adb"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }
}

/// Wraps `adb` subprocess. Streams `adb logcat` stdout as async lines.
final class AdbProcess: @unchecked Sendable {
    private var process: Process?

    /// Build (executableURL, arguments) for an adb action. Uses concrete path when available,
    /// else `/usr/bin/env adb` so PATH is consulted at runtime.
    static func buildCommand(action: [String], deviceId: String?) -> (URL, [String]) {
        var args: [String] = []
        if let id = deviceId, !id.isEmpty { args += ["-s", id] }
        args += action
        if let path = AdbLocator.resolvedPath() {
            return (URL(fileURLWithPath: path), args)
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["adb"] + args)
    }

    /// Live `adb logcat -v threadtime` line stream. Cancelling the iteration terminates adb.
    ///
    /// Reading is done manually (availableData → byte buffer → split on `\n` → UTF-8 decode)
    /// rather than `FileHandle.bytes.lines`, so multi-byte UTF-8 (e.g. Chinese) crossing
    /// chunk boundaries is reassembled correctly and never mojibake'd.
    func logcatLines(deviceId: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let (launch, args) = Self.buildCommand(action: ["logcat", "-v", "threadtime"], deviceId: deviceId)
            let p = Process()
            p.executableURL = launch
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let handle = pipe.fileHandleForReading

            continuation.onTermination = { [weak self] _ in
                p.terminate()
                self?.process = nil
            }

            do {
                try p.run()
                self.process = p
            } catch {
                continuation.finish(throwing: error)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }  // EOF / adb terminated
                    buffer.append(chunk)
                    // Data's startIndex advances after removeFirst, so always compute the
                    // line range and removal count relative to the current startIndex.
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let start = buffer.startIndex
                        var lineData = buffer[start..<nl]
                        buffer.removeFirst(nl - start + 1)
                        if lineData.last == 0x0D { lineData.removeLast() }   // strip CR
                        continuation.yield(String(decoding: lineData, as: UTF8.self))
                    }
                }
                if !buffer.isEmpty {
                    continuation.yield(String(decoding: buffer, as: UTF8.self))
                }
                continuation.finish()
            }
        }
    }

    func terminate() {
        process?.terminate()
        process = nil
    }
}
