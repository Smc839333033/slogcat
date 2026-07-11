import AppKit
import SwiftUI

@main
struct SlogcatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = LogStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(store.theme.isDark ? .dark : .light)
                .frame(minWidth: 900, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
    }
}

/// SPM-executable SwiftUI apps launch without a regular activation policy, so the window
/// never becomes key and TextFields can't receive keyboard input. Force it regular + activate.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
