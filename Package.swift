// swift-tools-version: 6.0
import PackageDescription

// macOS 26 is the floor on purpose. This is a personal build for one machine
// (Darwin 25.6 / macOS 26.6), so there is no reason to carry the compat shims
// the upstream project needed to support macOS 14: no hand-rolled outside-click
// monitor, no NSHostingView workarounds, native MenuBarExtra and SwiftData only.
let package = Package(
    name: "PokeBar",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "PokeBar",
            path: "Sources/PokeBar",
            swiftSettings: [
                // Surface data races at compile time rather than as the
                // generation-counter whack-a-mole the upstream defect log records.
                .swiftLanguageMode(.v6),
            ]
            // No sqlite3 link: Claude Code usage is append-only JSONL. The
            // upstream project needed SQLite only for Codex, Cursor, Copilot
            // and Kiro, all of which we deliberately do not track.
        ),
        .testTarget(
            name: "PokeBarTests",
            dependencies: ["PokeBar"],
            path: "Tests/PokeBarTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
