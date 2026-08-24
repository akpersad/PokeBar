import Foundation

/// A dated copy of `game-state.json`, taken on launch **before the save is read**.
///
/// The existing protection, `game-state.unreadable.json`, is written only when a
/// decode throws (`GameMonitor.load()`). That covers a corrupt file. It does not
/// cover the failure that actually threatens a collection: a save that decodes
/// perfectly and is *wrong*, because a migration seeded the wrong default or a
/// `persist()` wrote an empty roster over a real one. Nothing throws, nothing is
/// quarantined, and the next write makes it permanent. The usage ledger can be
/// rebuilt by rescanning `~/.claude`; a Pokemon caught last week cannot.
///
/// Two deliberate choices, both about a crash loop:
///
/// - **Backups are day-stamped, not per-launch.** An app that launches, writes a
///   bad save, and dies would otherwise burn through every good copy in ten
///   launches, which could be ten seconds.
/// - **The first capture of a day wins**; later launches that day copy nothing.
///   So today's backup is the save as it stood *before* today ran, and a bad
///   write today cannot reach any backup at all until tomorrow.
///
/// No clock and no `Date()` of its own: the day comes in as an argument, so the
/// pruning can be tested across eleven days without waiting eleven days.
struct SaveBackup {

    /// How many daily copies to keep. Ten days is well past the point where a
    /// player would notice a collection had gone wrong.
    static let keep = 10

    /// The save being protected. The backup directory and the file names are
    /// both derived from it, so nothing can drift if it is ever renamed.
    let stateURL: URL

    var directory: URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("backups")
    }

    /// `game-state`, from `game-state.json`.
    private var stem: String {
        stateURL.deletingPathExtension().lastPathComponent
    }

    /// Copies the save aside if today has no copy yet, then prunes.
    ///
    /// Returns the backup for today, whether or not this call is the one that
    /// wrote it, or nil when there is no save to protect. Never throws: a
    /// launch must not fail because a backup could not be taken.
    @discardableResult
    func capture(on date: Date = Date(), calendar: Calendar = .current) -> URL? {
        // Local calendar, matching invariant 9. A backup stamped in UTC would
        // roll over mid-evening here and label a day's copy with the next day.
        let day = ClaudeUsageParser.localDayKey(date, calendar: calendar)
        let destination = directory.appendingPathComponent("\(stem)-\(day).json")

        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            print("PokeBar: could not back up \(stateURL.lastPathComponent): \(error)")
            return nil
        }

        prune()
        return destination
    }

    /// Deletes all but the newest `keep` copies.
    ///
    /// Sorted by **file name**, which is the age order because the stamp is
    /// `yyyy-MM-dd` and sorts lexicographically. Modification date would be the
    /// wrong key: it says when a copy was taken, and what matters is which day's
    /// state it holds.
    ///
    /// Only called after a copy is written, because that is the only moment the
    /// count can have grown.
    private func prune() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let backups = names
            .filter { $0.hasPrefix("\(stem)-") && $0.hasSuffix(".json") }
            .sorted()
        guard backups.count > Self.keep else { return }
        for name in backups.dropLast(Self.keep) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
