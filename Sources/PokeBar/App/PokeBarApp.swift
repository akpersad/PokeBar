import AppKit
import SwiftUI

@main
struct PokeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var monitor = UsageMonitor()

    var body: some Scene {
        // Native MenuBarExtra in .window style. The upstream project could not
        // use this: it targets macOS 14, where dismissal behaviour forced a
        // hand-rolled NSEvent global monitor (their OutsideClickMonitor, plus
        // the idempotency fix in their #168). On macOS 26 the platform handles it.
        MenuBarExtra {
            UsagePopover(monitor: monitor)
        } label: {
            // The label is the one view that exists for the whole run, so it is
            // where the engine is started. `start()` is idempotent, so a rebuild
            // of the status item cannot launch a second scan loop.
            MenuBarLabel(monitor: monitor)
                .task { monitor.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock tile, no window on launch. This is normally
        // LSUIElement in an app bundle's Info.plist, but bundling and signing are
        // deferred until this runs daily (see DECISIONS.md), and `swift run` has
        // no plist to read.
        NSApp.setActivationPolicy(.accessory)
    }
}
