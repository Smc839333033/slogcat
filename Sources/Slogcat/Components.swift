import AppKit
import SwiftUI

/// Central tuning knobs for buffering / cadence.
enum LogConfig {
    /// Default max lines kept in the NSTextView. The actual runtime value is user-configurable
    /// via UserDefaults (key: LogConfig.displayCapKey); this is just the fallback default.
    static let defaultDisplayCap      = 20_000
    static let trimBatch             = 2_000    // lines dropped from the front when over cap
    static let defaultPendingCap     = 20_000   // max pending lines while UI is frozen
    static let drainIntervalMs: UInt64    = 50  // UI drain tick (smoother than 100ms)
    static let recomputeDebounceMs: UInt64 = 50  // filter recompute debounce (discrete actions)
    static let drainMaxLinesPerTick  = 2_000   // cap per-tick append → smooth burst-resume
    static let devicePollIntervalMs: UInt64 = 2_000  // background `adb devices` poll → hot-plug detection

    // UserDefaults keys
    static let fontSizeKey    = "fontSize"
    static let displayCapKey  = "displayCap"
    static let appearanceKey  = "appearance"
}

/// Faint dot-matrix grid — Nothing-style background texture.
struct DotGridBackground: View {
    var spacing: CGFloat = 14
    var dotSize: CGFloat = 1.2
    var color: Color = LogTheme.dotGrid   // resolved at render time → responds to appearance

    var body: some View {
        Canvas { ctx, size in
            let cols = Int(size.width / spacing) + 2
            let rows = Int(size.height / spacing) + 2
            var path = Path()
            let r = dotSize / 2
            for row in 0..<rows {
                for col in 0..<cols {
                    let cx = spacing * CGFloat(col) + spacing / 2
                    let cy = spacing * CGFloat(row) + spacing / 2
                    path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: dotSize, height: dotSize))
                }
            }
            ctx.fill(path, with: .color(color))
        }
    }
}

/// Accesses the enclosing NSWindow to apply AppKit-level tweaks not exposed by SwiftUI.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            if let w = v?.window { configure(w) }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let w = nsView.window { configure(w) }
        }
    }
}

/// NSView that forces the pointing-hand cursor over its bounds via cursor rects — the
/// AppKit-native, reliable way (NSCursor push/pop from SwiftUI gets reset by the window).
final class CursorView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
struct PointerCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ nsView: CursorView, context: Context) {}
}

/// Toolbar icon-button style: hover highlight + clear press feedback (background flash +
/// slight scale) so a click never feels ignored. Also shows the pointing-hand cursor.
struct ToolbarIconButtonStyle: ButtonStyle {
    var disabled: Bool = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let active = configuration.isPressed && !disabled
        let hover = hovering && !disabled
        configuration.label
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(active ? LogTheme.accent.opacity(0.35)
                                 : (hover ? LogTheme.controlHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(active ? LogTheme.accent
                                   : (hover ? LogTheme.borderStrong : Color.clear),
                            lineWidth: 1)
            )
            .scaleEffect(active ? 0.86 : 1.0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
            .background(disabled ? nil : PointerCursor())
            .onHover { hovering = $0 }
    }
}

/// Press feedback for custom-labelled buttons (device picker, etc.): dims + shrinks slightly
/// on press so the tap registers visually. Pairs with the button's own background/border.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .background(PointerCursor())
    }
}
