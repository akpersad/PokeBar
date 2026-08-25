import Foundation
import ServiceManagement

/// "Open at login", through `SMAppService` rather than a hand-written LaunchAgent
/// plist in `~/Library/LaunchAgents`.
///
/// **Why the framework and not a plist.** A plist has to name an absolute path to
/// the bundle, and this bundle lives at `dist/PokeBar.app` inside a working copy;
/// a rebuild is fine but a `swift package clean` or a move leaves a login item
/// pointing at nothing, silently, until the user notices the app stopped
/// starting. `SMAppService.mainApp` registers *this* bundle by identity, is
/// removed when the app is deleted, and shows up in System Settings where a user
/// would look for it. It is also the only route Apple supports from macOS 13 on.
///
/// **Nothing is lost while the app is off**, which is why this is quality of life
/// and not a fix: cursors persist, so a launch after three days credits those
/// three days. What it buys is the passive notification set actually firing when
/// the events happen rather than arriving in a batch at the next launch.
@MainActor
enum LoginItem {

    /// What the toggle should show.
    ///
    /// A local enum rather than `SMAppService.Status` so the copy that describes
    /// each case is testable: `Status` cannot be constructed in a test, and this
    /// can.
    enum State: Equatable, Sendable {
        case on
        case off
        /// Registered, but macOS wants the user to allow it in System Settings.
        /// Ad-hoc signed builds land here more often than notarised ones.
        case needsApproval
        /// No app bundle, so there is nothing to register. `swift run PokeBar`,
        /// and the test runner.
        case unavailable
    }

    /// The same guard `Notifier` uses, and for the same reason: these APIs assume
    /// a real bundle and a bare SwiftPM executable does not have one.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var state: State {
        guard isAvailable else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    /// Turns it on or off. Throws what the framework throws, so the popover can
    /// say what went wrong rather than leaving a toggle that quietly springs back.
    static func set(_ enabled: Bool) throws {
        guard isAvailable else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
