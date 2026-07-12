import AppKit
import SwiftUI

/// Appearance mode: dark (Nothing-style charcoal) or light (day mode).
enum Appearance: String, CaseIterable, Identifiable {
    case dark
    case light
    var id: String { rawValue }
    var label: String { self == .dark ? "夜间" : "日间" }
}

/// Observable theme manager. Stored in LogStore so the whole app reacts to appearance changes.
@Observable
final class ThemeManager {
    var appearance: Appearance = {
        let v = UserDefaults.standard.string(forKey: LogConfig.appearanceKey)
        return Appearance(rawValue: v ?? "") ?? .dark
    }()

    var isDark: Bool { appearance == .dark }

    func toggle() {
        appearance = (appearance == .dark) ? .light : .dark
        UserDefaults.standard.set(appearance.rawValue, forKey: LogConfig.appearanceKey)
    }

    func set(_ a: Appearance) {
        guard a != appearance else { return }
        appearance = a
        UserDefaults.standard.set(a.rawValue, forKey: LogConfig.appearanceKey)
    }
}

/// Nothing-inspired theme: charcoal (not pure black), high contrast, monospace, red accent.
/// Colors are resolved at call time based on ThemeManager.appearance.
enum LogTheme {
    // MARK: - Dark palette
    private enum Dark {
        static let background     = Color(white: 0.10)
        static let surface        = Color(white: 0.13)
        static let surfaceRaised  = Color(white: 0.16)
        static let border         = Color.white.opacity(0.12)
        static let borderStrong   = Color.white.opacity(0.24)
        static let textPrimary    = Color.white
        static let textSecondary  = Color(white: 0.45)
        static let dotGrid        = Color.white.opacity(0.09)
        static let controlHover   = Color.white.opacity(0.16)   // button hover — visible on charcoal
    }

    // MARK: - Light palette
    private enum Light {
        static let background     = Color(white: 0.96)     // warm off-white
        static let surface        = Color(white: 0.92)
        static let surfaceRaised  = Color(white: 0.88)
        static let border         = Color.black.opacity(0.12)
        static let borderStrong   = Color.black.opacity(0.24)
        static let textPrimary    = Color(white: 0.08)
        static let textSecondary  = Color(white: 0.50)
        static let dotGrid        = Color.black.opacity(0.13)
        static let controlHover   = Color.black.opacity(0.10)   // button hover — visible on off-white
    }

    // MARK: - Resolved colors (read ThemeManager at call time)
    static var background:    Color { ThemeManagerShared.isDark ? Dark.background    : Light.background }
    static var surface:       Color { ThemeManagerShared.isDark ? Dark.surface       : Light.surface }
    static var surfaceRaised: Color { ThemeManagerShared.isDark ? Dark.surfaceRaised : Light.surfaceRaised }
    static var border:        Color { ThemeManagerShared.isDark ? Dark.border        : Light.border }
    static var borderStrong:  Color { ThemeManagerShared.isDark ? Dark.borderStrong  : Light.borderStrong }
    static var textPrimary:   Color { ThemeManagerShared.isDark ? Dark.textPrimary   : Light.textPrimary }
    static var textSecondary: Color { ThemeManagerShared.isDark ? Dark.textSecondary : Light.textSecondary }
    static var dotGrid:       Color { ThemeManagerShared.isDark ? Dark.dotGrid        : Light.dotGrid }
    static var controlHover:  Color { ThemeManagerShared.isDark ? Dark.controlHover   : Light.controlHover }
    static let accent         = Color(red: 1.0, green: 0.05, blue: 0.05)   // Nothing red — same in both

    // Back-compat aliases
    static let panel          = surface
    static let panelBorder    = border

    /// Uppercase-style monospace label used for section titles / button labels.
    static func labelFont(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }

    static func color(for level: LogLevel) -> Color {
        switch level {
        case .verbose: return Color(red: 0.50, green: 0.42, blue: 0.70)   // deeper lavender — visible on light
        case .debug:   return Color(red: 0.10, green: 0.55, blue: 0.85)
        case .info:    return Color(red: 0.20, green: 0.60, blue: 0.30)   // deeper sage green
        case .warn:    return Color(red: 0.85, green: 0.65, blue: 0.10)
        case .error:   return Color(red: 0.85, green: 0.20, blue: 0.20)
        case .fatal:   return Color(red: 0.75, green: 0.10, blue: 0.15)
        }
    }
}

/// Shared ThemeManager instance — set by LogStore at init. LogTextBuilder (AppKit side) and
/// LogTheme (SwiftUI side) both read from this so a single toggle flips the whole app.
var ThemeManagerShared = ThemeManager()

/// Thin-bordered, dark, monospace input field — matches the technical look.
struct TechField: ViewModifier {
    var width: CGFloat? = nil
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(LogTheme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(width: width)
            .background(LogTheme.surfaceRaised)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(LogTheme.border))
    }
}

extension View {
    func techField(width: CGFloat? = nil) -> some View { modifier(TechField(width: width)) }
}
