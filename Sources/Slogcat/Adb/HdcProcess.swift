import Foundation

/// Resolves the `hdc` (HarmonyOS Device Connector) executable path:
///   user override (UserDefaults) → `which hdc` (PATH) → common HarmonyOS SDK locations → nil.
///
/// Mirrors AdbLocator. When resolvedPath() returns nil, HarmonyOS support silently disables
/// itself (no polling, no error) so Android-only users are never affected.
enum HdcLocator {
    static let userPathKey = "hdcPath"

    static var userPath: String? {
        get { UserDefaults.standard.string(forKey: userPathKey) }
        set { UserDefaults.standard.set(newValue, forKey: userPathKey) }
    }

    /// Concrete path if found, else nil (caller silently skips HarmonyOS).
    static func resolvedPath() -> String? {
        if let user = userPath, !user.isEmpty,
           FileManager.default.isExecutableFile(atPath: user) {
            return user
        }
        if let p = whichHdc(), FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            // DevEco Studio app bundle (most common install on macOS).
            "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
            "/Applications/DevEco-Studio.app/Contents/sdk/default/hms/toolchains/hdc",
            "\(home)/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
            // Command-line-tools / standalone SDK installs.
            "\(home)/Library/Huawei/Sdk/openharmony/toolchains/hdc",
            "\(home)/Library/OpenHarmony/Sdk/toolchains/hdc",
            "\(home)/Library/Huawei/sdk/toolchains/hdc",
            "\(home)/command-line-tools/sdk/default/openharmony/toolchains/hdc",
            "/usr/local/bin/hdc",
            "/opt/homebrew/bin/hdc"
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // Last resort: glob DevEco Studio's sdk dir (version subfolders vary), and the
        // Huawei SDK root under ~/Library, for any `.../toolchains/hdc`.
        if let p = searchToolchains() { return p }
        return nil
    }

    /// Scan known SDK roots for a `toolchains/hdc` at any depth. Handles version-numbered
    /// subfolders (e.g. `sdk/12/...`) that fixed candidate paths can't anticipate.
    private static func searchToolchains() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [
            "/Applications/DevEco-Studio.app/Contents/sdk",
            "\(home)/Applications/DevEco-Studio.app/Contents/sdk",
            "\(home)/Library/Huawei/Sdk",
            "\(home)/Library/OpenHarmony/Sdk",
            "\(home)/Library/Huawei/sdk"
        ]
        let fm = FileManager.default
        for root in roots {
            guard let en = fm.enumerator(atPath: root) else { continue }
            for case let rel as String in en {
                // Prune deep traversal for speed.
                if (rel as NSString).pathComponents.count > 6 { en.skipDescendants(); continue }
                if rel.hasSuffix("toolchains/hdc") {
                    let full = (root as NSString).appendingPathComponent(rel)
                    if fm.isExecutableFile(atPath: full) { return full }
                }
            }
        }
        return nil
    }

    // MARK: `which hdc` (cached, runs once)

    /// `String??`: nil = not yet probed; .some(.some(path)) = found; .some(nil) = probed, not found.
    private static var whichCache: String?? = nil
    private static let whichLock = NSLock()

    private static func whichHdc() -> String? {
        whichLock.lock()
        let cached = whichCache
        whichLock.unlock()
        if let c = cached { return c }
        let found = runWhich()
        whichLock.lock()
        whichCache = .some(found)
        whichLock.unlock()
        return found
    }

    private static func runWhich() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "hdc"]
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

/// Wraps `hdc` subprocess. Streams `hdc shell hilog` stdout as async lines.
///
/// Structured identically to AdbProcess (same manual UTF-8 line splitting so multi-byte
/// characters crossing chunk boundaries are reassembled correctly), differing only in the
/// executable resolved (hdc), the device flag (`-t` instead of `-s`), and the log command
/// (`shell hilog`).
final class HdcProcess: @unchecked Sendable {
    private var process: Process?

    /// Build (executableURL, arguments) for an hdc action. Uses concrete path when available,
    /// else `/usr/bin/env hdc` so PATH is consulted at runtime. hdc selects a device with `-t`.
    static func buildCommand(action: [String], deviceId: String?) -> (URL, [String]) {
        var args: [String] = []
        if let id = deviceId, !id.isEmpty { args += ["-t", id] }
        args += action
        if let path = HdcLocator.resolvedPath() {
            return (URL(fileURLWithPath: path), args)
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["hdc"] + args)
    }

    /// Live `hdc shell hilog` line stream. Cancelling the iteration terminates hdc.
    func hilogLines(deviceId: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let (launch, args) = Self.buildCommand(action: ["shell", "hilog"], deviceId: deviceId)
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
                    if chunk.isEmpty { break }  // EOF / hdc terminated
                    buffer.append(chunk)
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
