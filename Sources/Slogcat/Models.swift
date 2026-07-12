import Foundation

/// Source platform for a device / log stream. Android uses adb+logcat, HarmonyOS uses
/// hdc+hilog. Log line formats differ per platform, so the parser is dispatched on this.
enum Platform: String, Sendable, Hashable, CaseIterable {
    case android
    case harmony

    /// Short tag shown in the device list / picker.
    var label: String {
        switch self {
        case .android: return "ADB"
        case .harmony: return "HDC"
        }
    }
}

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
    /// Which platform produced this line. Defaults to .android so existing call sites and
    /// the Android path are unaffected.
    var platform: Platform = .android

    /// Reconstructed threadtime-style line for copy/export.
    var rawLine: String {
        if timestamp.isEmpty { return message }
        return "\(timestamp) \(pid) \(tid) \(level.rawValue) \(tag): \(message)"
    }
}

struct Device: Identifiable, Sendable, Hashable {
    let id: String
    let state: String
    /// Which tool this device is reachable through (adb vs hdc). Defaults to .android.
    var platform: Platform = .android
    var displayName: String { "[\(platform.label)] " + id + " · " + state }
}

// MARK: - Filter rules

/// Combined field + mode for a filter rule, shown in the composer dropdown. Folds the old
/// standalone Tag/PID inputs into the per-rule dropdown.
enum FilterKind: String, CaseIterable, Identifiable, Sendable {
    case msgInclude    = "内容·包含"
    case msgExclude    = "内容·排除"
    case msgIncludeRx  = "内容·正则"
    case msgExcludeRx  = "内容·正则排除"
    case tagInclude    = "Tag·包含"
    case tagExclude    = "Tag·排除"
    case tagIncludeRx  = "Tag·正则"
    case tagExcludeRx  = "Tag·正则排除"
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

    /// The field this rule targets — used to group the dropdown.
    enum Field: String, CaseIterable, Identifiable { case message = "内容", tag = "Tag", pid = "PID"; var id: String { rawValue } }
    var field: Field {
        switch self {
        case .msgInclude, .msgExclude, .msgIncludeRx, .msgExcludeRx: return .message
        case .tagInclude, .tagExclude, .tagIncludeRx, .tagExcludeRx: return .tag
        case .pidEquals: return .pid
        }
    }

    /// Short mode label shown in the dropdown row and on committed chips.
    var modeLabel: String {
        switch self {
        case .msgInclude, .tagInclude:     return "包含"
        case .msgExclude, .tagExclude:     return "排除"
        case .msgIncludeRx, .tagIncludeRx: return "正则匹配"
        case .msgExcludeRx, .tagExcludeRx: return "正则排除"
        case .pidEquals:                   return "等于"
        }
    }

    /// SF Symbol representing the mode — include=✓, exclude=⊘, regex adds the `.*` glyph.
    var icon: String {
        switch self {
        case .msgInclude, .tagInclude:     return "checkmark"
        case .msgExclude, .tagExclude:     return "nosign"
        case .msgIncludeRx, .tagIncludeRx: return "text.magnifyingglass"
        case .msgExcludeRx, .tagExcludeRx: return "xmark.circle"
        case .pidEquals:                   return "number"
        }
    }

    /// One-line plain-language explanation shown under each dropdown row.
    var hint: String {
        switch self {
        case .msgInclude:   return "仅显示内容含此文字的日志"
        case .msgExclude:   return "隐藏内容含此文字的日志"
        case .msgIncludeRx: return "内容匹配正则表达式则显示"
        case .msgExcludeRx: return "内容匹配正则表达式则隐藏"
        case .tagInclude:   return "仅显示 Tag 含此文字的日志"
        case .tagExclude:   return "隐藏 Tag 含此文字的日志"
        case .tagIncludeRx: return "Tag 匹配正则表达式则显示"
        case .tagExcludeRx: return "Tag 匹配正则表达式则隐藏"
        case .pidEquals:    return "仅显示指定进程 ID 的日志"
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

