import Foundation

enum LogLevel: String, CaseIterable, Identifiable, Sendable {
    case verbose = "V"
    case debug = "D"
    case info = "I"
    case warn = "W"
    case error = "E"
    case fatal = "F"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .verbose: return "Verbose"
        case .debug: return "Debug"
        case .info: return "Info"
        case .warn: return "Warn"
        case .error: return "Error"
        case .fatal: return "Fatal"
        }
    }
}

struct LogEntry: Identifiable, Sendable, Hashable {
    let id: UInt64
    let timestamp: String
    let pid: Int
    let tid: Int
    let level: LogLevel
    let tag: String
    let message: String

    /// Reconstructed threadtime-style line for copy/export.
    var rawLine: String {
        if timestamp.isEmpty { return message }
        return "\(timestamp) \(pid) \(tid) \(level.rawValue) \(tag): \(message)"
    }
}

struct Device: Identifiable, Sendable, Hashable {
    let id: String
    let state: String
    var displayName: String { id + " · " + state }
}

// MARK: - Filter rules

/// Combined field + mode for a filter rule, shown in the composer dropdown. Folds the old
/// standalone Tag/PID inputs into the per-rule dropdown.
enum FilterKind: String, CaseIterable, Identifiable, Sendable {
    case msgInclude    = "内容·包含"
    case msgExclude    = "内容·排除"
    case msgIncludeRx  = "内容·正含"
    case msgExcludeRx  = "内容·正排"
    case tagInclude    = "Tag·包含"
    case tagExclude    = "Tag·排除"
    case tagIncludeRx  = "Tag·正含"
    case tagExcludeRx  = "Tag·正排"
    case pidEquals     = "PID·等于"

    var id: String { rawValue }
    var isExclude: Bool {
        switch self {
        case .msgExclude, .msgExcludeRx, .tagExclude, .tagExcludeRx: return true
        default: return false
        }
    }
    var isRegex: Bool {
        switch self {
        case .msgIncludeRx, .msgExcludeRx, .tagIncludeRx, .tagExcludeRx: return true
        default: return false
        }
    }
}

/// Reference type so SwiftUI binds directly to the rule object (no array-index bindings
/// that can go stale on deletion). @Observable drives the enable-toggle UI.
@Observable
final class FilterRule: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var kind: FilterKind
    var enabled: Bool = true

    init(text: String, kind: FilterKind = .msgInclude) {
        self.text = text
        self.kind = kind
    }

    static func == (lhs: FilterRule, rhs: FilterRule) -> Bool { lhs.id == rhs.id }
}

/// Raw filter config compiled by FilterEngine. Stays on the main actor; only the compiled
/// `FilterEngine.Compiled` crosses into the pipeline.
struct FilterSpec {
    var enabledLevels: Set<LogLevel>
    var rules: [FilterRule]
}

