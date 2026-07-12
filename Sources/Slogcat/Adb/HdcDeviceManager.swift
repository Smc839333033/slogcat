import Foundation

/// Runs `hdc list targets` and parses output. Blocking call is offloaded to a global queue.
/// Mirrors DeviceManager (the Android equivalent) but for HarmonyOS devices.
///
/// If hdc is not installed, listDevices() returns [] silently — HarmonyOS support disables
/// itself and Android-only users are unaffected.
enum HdcDeviceManager {
    static func listDevices() async -> [Device] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: listDevicesSync())
            }
        }
    }

    private static func listDevicesSync() -> [Device] {
        // No hdc → no HarmonyOS devices, no error.
        guard HdcLocator.resolvedPath() != nil else { return [] }

        let (launch, args) = HdcProcess.buildCommand(action: ["list", "targets"], deviceId: nil)
        let p = Process()
        p.executableURL = launch
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// `hdc list targets` prints one serial per line, or `[Empty]` when nothing is connected.
    /// Occasionally emits informational lines (e.g. daemon start-up); we keep only tokens that
    /// look like a device serial.
    private static func parse(_ text: String) -> [Device] {
        var devices: [Device] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "[Empty]" { continue }
            // Skip obvious non-serial noise.
            let lower = trimmed.lowercased()
            if lower.hasPrefix("[") || lower.contains("empty")
                || lower.contains("no ") || lower.contains("error")
                || lower.contains("cannot") || lower.contains("connect") { continue }
            // A serial is a single whitespace-free token; take the first token defensively.
            let serial = trimmed.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init).first ?? trimmed
            if serial.isEmpty { continue }
            devices.append(Device(id: serial, state: "device", platform: .harmony))
        }
        return devices
    }
}
