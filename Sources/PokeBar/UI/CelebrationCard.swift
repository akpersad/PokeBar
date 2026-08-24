import SwiftUI

/// The moment after a hatch.
///
/// **Built because the feed was not enough.** A 300 coin egg used to announce
/// itself as one grey line in a four-row activity list, under the button that
/// bought it, and the first thing a player did with the team was miss it
/// entirely. The rule this settles: the popover celebrates what you *clicked*,
/// and the notifier announces what happened while you were not looking. An
/// evolution therefore never lands here.
///
/// Dismissed by a click anywhere, and by nothing else. No timer: a card that
/// vanishes while it is being read is worse than one that has to be waved away,
/// and the sprite it draws may still be arriving from the network.
struct CelebrationCard: View {
    let game: GameMonitor
    let store: SpriteStore
    let celebration: Celebration

    private var entry: DexEntry? { game.entry(id: celebration.entryID) }

    var body: some View {
        ZStack {
            // Swallows the click that dismisses, and dims the pane behind so the
            // card reads as the only thing on screen.
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
            if let entry, let dex = game.dex {
                VStack(spacing: 8) {
                    SpriteTile(
                        entry: entry, variant: celebration.variant, dex: dex, store: store,
                        height: 84)
                        .shadow(color: shine.opacity(0.55), radius: 18)

                    Text(GameFormat.celebrationTitle(celebration, name: entry.name))
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)

                    Text(GameFormat.celebrationSubtitle(celebration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Click anywhere to carry on")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                .padding(18)
                .frame(maxWidth: PopoverMetrics.contentWidth - 20)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(shine.opacity(0.7), lineWidth: 1))
                .shadow(radius: 20)
            }
        }
        .onTapGesture { game.dismissCelebration() }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(
            entry.map {
                GameFormat.celebrationTitle(celebration, name: $0.name) + ". "
                    + GameFormat.celebrationSubtitle(celebration)
            } ?? "Caught something")
        .accessibilityHint("Click to dismiss")
    }

    /// Gold for a shiny, which is the only 1 in 64 thing that happens here, and
    /// the app's usual green otherwise.
    private var shine: Color { celebration.variant.shiny ? .yellow : .green }
}
