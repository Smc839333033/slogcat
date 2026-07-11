import Foundation

/// Runs `adb devices` and parses output. Blocking call is offloaded to a global queue.
enum DeviceManager {
    static func listDevices() async -> [Device] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: listDevicesSync())
            }
        }
    }

    private static func listDevicesSync() -> [Device] {
        let (launch, args) = AdbProcess.buildCommand(action: ["devices"], deviceId: nil)
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

    private static func parse(_ text: String) -> [Device] {
        var devices: [Device] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("List of devices") { continue }
            let parts = trimmed.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            if parts.count >= 2 {
                devices.append(Device(id: parts[0], state: parts[1]))
            }
        }
        return devices
    }
}
