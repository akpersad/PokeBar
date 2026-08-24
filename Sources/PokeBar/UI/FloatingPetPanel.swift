import AppKit
import SwiftUI

/// A borderless always-on-top window holding the Pokemon being raised.
///
/// Independent of the menu bar item, and carried over from upstream because it is
/// the one part of that project this one wanted wholesale. The status item is a
/// 20pt sprite you glance at; the pet is a companion sitting on the desktop at a
/// size where the animation is actually visible.
///
/// It is an `NSPanel` rather than a SwiftUI `Window` scene for three reasons that
/// SwiftUI has no vocabulary for: it must float above ordinary windows without
/// stealing focus, it must follow the user across Spaces, and it must be
/// click-dragged by its own transparent background. A non-activating panel gets
/// all three; a `Window` gets none of them.
@MainActor
@Observable
final class FloatingPet {

    private(set) var isVisible = false

    /// Sized for a desktop companion rather than a status item. The width cap is
    /// generous for the same reason the menu bar's is tight: fit to height and let
    /// wide species be wide, since nothing here is competing for horizontal space.
    static let height: CGFloat = 96
    static let maxWidth: CGFloat = 160

    private let animator: SpriteAnimator
    private var panel: NSPanel?

    init(pokedex: Pokedex?, store: SpriteStore) {
        self.animator = SpriteAnimator(
            pokedex: pokedex, store: store, height: Self.height, maxWidth: Self.maxWidth)
    }

    /// Follows whatever the status item is showing, so the pet is always the
    /// Pokemon being raised rather than a second, stale opinion about it.
    func show(_ entry: DexEntry, variant: SpriteVariant) async {
        await animator.show(entry, variant: variant)
    }

    func toggle() {
        isVisible ? hide() : present()
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        isVisible = true
    }

    private func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.maxWidth, height: Self.height + 8),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // Dragged by its own background, since it has no title bar to grab.
        panel.isMovableByWindowBackground = true
        // Follows the user between Spaces and survives a full-screen app, which is
        // the difference between a companion and a window you keep losing.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: FloatingPetView(animator: animator))
        // AppKit remembers where it was left, so the pet does not jump back to the
        // corner on every launch.
        panel.setFrameAutosaveName("PokeBarFloatingPet")
        if panel.frame.origin == .zero, let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - Self.maxWidth - 40,
                y: screen.visibleFrame.minY + 40))
        }
        return panel
    }
}

/// The pet's contents: the sprite, and nothing else.
///
/// No frame modifier on the image, for the same reason the status item has none:
/// the decoder already produced it at its display size, fitted to height with
/// width free, so an imposed frame can only distort it.
private struct FloatingPetView: View {
    let animator: SpriteAnimator

    var body: some View {
        ZStack {
            if let frame = animator.frame {
                Image(decorative: frame, scale: 2)
            }
        }
        .frame(width: FloatingPet.maxWidth, height: FloatingPet.height + 8)
        .contentShape(Rectangle())
        .accessibilityLabel(animator.entry.map { "\($0.name), desktop companion" } ?? "PokeBar pet")
    }
}
