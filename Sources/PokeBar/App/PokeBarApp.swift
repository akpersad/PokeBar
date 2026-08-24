import AppKit
import SwiftUI

@main
struct PokeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // One dex and one sprite store for the whole app. Sharing the store matters:
    // it holds the in-flight table that keeps a dex page of 30 tiles from opening
    // 30 requests for the same sprite, and the memory cache that survives a tab
    // switch.
    //
    // A dex that fails to load must not take the usage engine down with it, so
    // everything downstream degrades to a symbol. A test asserts the bundled
    // manifest actually loads, which is where that failure surfaces rather than
    // as a silently Pokemon-less menu bar.
    private static let dex = try? Pokedex.loadBundled()
    private static let store = SpriteStore()

    @State private var monitor = UsageMonitor()
    @State private var game = GameMonitor(dex: PokeBarApp.dex)
    @State private var sprite = SpriteAnimator(pokedex: PokeBarApp.dex, store: PokeBarApp.store)

    var body: some Scene {
        // Native MenuBarExtra in .window style. The upstream project could not
        // use this: it targets macOS 14, where dismissal behaviour forced a
        // hand-rolled NSEvent global monitor (their OutsideClickMonitor, plus
        // the idempotency fix in their #168). On macOS 26 the platform handles it.
        MenuBarExtra {
            PokeBarPopover(monitor: monitor, game: game, store: Self.store)
        } label: {
            // The label is the one view that exists for the whole run, so it is
            // where the engine is started. `start()` is idempotent, so a rebuild
            // of the status item cannot launch a second scan loop.
            MenuBarLabel(monitor: monitor, game: game, sprite: sprite)
                .task {
                    // Hand the game its side of the credit before the first scan.
                    // Weighted tokens mint coins in the ledger and XP here, in
                    // parallel, never from a shared pool.
                    monitor.game = game
                    monitor.start()
                }
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
