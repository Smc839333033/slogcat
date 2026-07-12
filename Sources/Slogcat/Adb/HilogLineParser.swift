import Foundation

/// Parses `hdc shell hilog` lines (HarmonyOS / OpenHarmony HiLog).
///
/// The command-line hilog format is threadtime-like but the tag carries a `domain/` hex
/// prefix, and the level letter set differs slightly from Android (no Verbose; but we stay
/// tolerant of any single uppercase letter):
///   `MM-DD HH:MM:SS.mmm  PID  TID L domain/tag: MESSAGE`
///   `08-06 15:23:10.123  1234  5678 I 0xD003200/MyTag: message text`
///
/// The full `domain/tag` is preserved as the entry's tag (per product decision), so filtering
/// on tag can match either the domain or the tag name.
///
/// Kept entirely separate from LineParser so the Android parsing path is never touched.
enum HilogLineParser {
    static let regex: NSRegularExpression = {
        // Level group accepts any single uppercase letter so unknown/future levels don't drop
        // the whole line to the raw fallback; mapped to .info when not a known LogLevel.
        let pattern = #"^(\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\s+(\d+)\s+(\d+)\s+([A-Z])\s+(.+?)\s*:\s?(.*)$"#
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
            let tag = ns.substring(with: m.range(at: 5))   // full "domain/tag" kept as-is
            let message = ns.substring(with: m.range(at: 6))
            return LogEntry(id: seq, timestamp: timestamp, pid: pid, tid: tid,
                            level: level, tag: tag, message: message, platform: .harmony)
        }
        // Unparsable (hilog banner, blank line, etc.) → keep as raw info line.
        return LogEntry(id: seq, timestamp: "", pid: 0, tid: 0, level: .info,
                        tag: "", message: line, platform: .harmony)
    }
}
