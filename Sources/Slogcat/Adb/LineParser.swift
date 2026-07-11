import Foundation

/// Parses `adb logcat -v threadtime` lines.
/// Format: `MM-DD HH:MM:SS.mmm PID TID L TAG: MESSAGE`
enum LineParser {
    static let regex: NSRegularExpression = {
        let pattern = #"^(\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\s+(\d+)\s+(\d+)\s+([VDIWEF])\s+(.+?)\s*:\s?(.*)$"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    @inline(__always)
    static func parse(_ line: String, seq: UInt64) -> LogEntry {
        let ns = line as NSString
        if let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            let timestamp = ns.substring(with: m.range(at: 1))
            let pid = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let tid = Int(ns.substring(with: m.range(at: 3))) ?? 0
            let level = LogLevel(rawValue: ns.substring(with: m.range(at: 4))) ?? .info
            let tag = ns.substring(with: m.range(at: 5))
            let message = ns.substring(with: m.range(at: 6))
            return LogEntry(id: seq, timestamp: timestamp, pid: pid, tid: tid, level: level, tag: tag, message: message)
        }
        // Unparsable (adb banner, blank line, etc.) → keep as raw info line.
        return LogEntry(id: seq, timestamp: "", pid: 0, tid: 0, level: .info, tag: "", message: line)
    }
}
