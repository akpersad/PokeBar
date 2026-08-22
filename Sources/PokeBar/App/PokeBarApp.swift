import SwiftUI

@main
struct PokeBarApp: App {
    var body: some Scene {
        // Native MenuBarExtra in .window style. The upstream project could not
        // use this: it targets macOS 14, where dismissal behaviour forced a
        // hand-rolled NSEvent global monitor (their OutsideClickMonitor, plus
        // the idempotency fix in their #168). On macOS 26 the platform handles it.
        MenuBarExtra {
            PopoverRoot()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Placeholder until the usage engine lands. Kept deliberately dumb so the
/// first build validates the toolchain and nothing else.
private struct MenuBarLabel: View {
    var body: some View {
        Image(systemName: "circle.dotted")
    }
}

private struct PopoverRoot: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PokeBar")
                .font(.headline)
            Text("Usage engine not wired up yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit PokeBar") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 240)
    }
}
