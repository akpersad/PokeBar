import Foundation
import UserNotifications

/// Notifications for the things that happen while you are not looking.
///
/// **Most game events are deliberately silent.** A notification for something the
/// player just clicked is noise: they are looking at the popover, the result is
/// already on screen, and the alert arrives second. What earns an alert is an
/// event that happens on its own while the window is closed, which is exactly the
/// set that token accrual drives: an evolution, a graduation, and a choice that is
/// now waiting on the player. A shiny is the one exception, because a 1-in-64 roll
/// deserves saying out loud even when you were watching.
///
/// Level ups are excluded on volume alone. A full climb passes 99 of them.
///
/// **One credit can now reach six Pokemon at once**, which multiplies that volume
/// problem by six: an overnight batch can evolve four of them in a single tick.
/// So alerts of the same kind from one credit are *grouped* rather than posted one
/// by one. Nothing is dropped, it is summarised: three banners is the ceiling for
/// any single credit, and the names are all still in the body.
@MainActor
final class Notifier {

    /// Whether the process can post at all.
    ///
    /// `UNUserNotificationCenter.current()` traps for a process with no app
    /// bundle, and `swift run PokeBar` is exactly that. It is already a known
    /// failure mode here for a different reason (a bare executable draws no menu
    /// bar item at all), so this guard keeps the game usable when running that
    /// way instead of crashing on the first evolution.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Whether permission has been granted this run. Nil until asked.
    private var authorized: Bool?

    /// Whether the one-time "notifications are on" confirmation has been sent.
    /// In `UserDefaults` rather than in `Trainer`, because it is a fact about this
    /// machine's notification settings and not part of the collection.
    private static let confirmedKey = "PokeBarNotificationsConfirmed"

    /// The alert an event deserves, or nil for the ones that stay quiet.
    ///
    /// Pure and separate from posting, so the editorial decision about what is
    /// worth interrupting someone for is testable.
    nonisolated static func announcement(
        for event: GameEvent, dex: Pokedex
    ) -> (title: String, body: String)? {
        func name(_ id: Int) -> String { dex.entry(id: id)?.name ?? "#\(id)" }
        switch event {
        case .evolved(_, let from, let to):
            return ("\(name(from)) evolved", "It is now \(name(to)).")
        case .graduated(_, let entryID):
            return ("\(name(entryID)) graduated", "Level 100. Time to raise something else.")
        case .evolutionChoice(_, let from, let options):
            let names = options.map(name).joined(separator: " or ")
            return ("\(name(from)) is ready to evolve", "Into \(names). Pick one in PokeBar.")
        case .caught(let event) where event.variant.shiny:
            // Shiny is the only caught event loud enough to interrupt for, and
            // only when it was rolled rather than inherited from an evolution:
            // an evolving shiny was already announced when it hatched.
            guard event.source == .hatch || event.source == .reroll else { return nil }
            return ("Shiny \(name(event.entryID))", "One in \(Prices.shinyOdds). Nice.")
        case .caught, .duplicate, .levelledUp:
            return nil
        }
    }

    /// Every alert one batch of events deserves, with same-kind alerts grouped.
    ///
    /// A team of six turns "an evolution happened" into "four evolutions
    /// happened", and six banners for one credit is the kind of thing that gets
    /// notifications turned off entirely. One evolution still reads as itself;
    /// several become one banner that names them all. Grouping is per kind rather
    /// than across kinds, because "3 updates" tells the player nothing and
    /// "3 Pokemon evolved" tells them everything.
    ///
    /// Shinies are never grouped: they only come from a hatch or a re-roll, which
    /// are single clicks, so a batch cannot contain two.
    nonisolated static func announcements(
        for events: [GameEvent], dex: Pokedex
    ) -> [(title: String, body: String)] {
        func name(_ id: Int) -> String { dex.entry(id: id)?.name ?? "#\(id)" }

        var evolved: [(from: Int, to: Int)] = []
        var graduated: [Int] = []
        var waiting: [(from: Int, options: [Int])] = []
        var others: [(title: String, body: String)] = []

        for event in events {
            switch event {
            case .evolved(_, let from, let to): evolved.append((from, to))
            case .graduated(_, let entryID): graduated.append(entryID)
            case .evolutionChoice(_, let from, let options): waiting.append((from, options))
            default:
                // Everything else keeps its own copy and its own banner, which
                // today means a shiny and nothing more.
                if let alert = announcement(for: event, dex: dex) { others.append(alert) }
            }
        }

        // A batch of one is not a batch: it uses the single-event copy, so the
        // common case reads exactly as it did before the team existed.
        var alerts: [(title: String, body: String)] = []
        if evolved.count > 1 {
            alerts.append((
                "\(evolved.count) Pokemon evolved",
                list(evolved.map { name($0.to) }) + ", all at once."))
        } else if let one = evolved.first {
            alerts.append(("\(name(one.from)) evolved", "It is now \(name(one.to))."))
        }
        if graduated.count > 1 {
            alerts.append((
                "\(graduated.count) Pokemon graduated",
                list(graduated.map(name)) + " all reached level 100."))
        } else if let one = graduated.first {
            alerts.append(
                ("\(name(one)) graduated", "Level 100. Time to raise something else."))
        }
        if waiting.count > 1 {
            alerts.append((
                "\(waiting.count) Pokemon are ready to evolve",
                list(waiting.map { name($0.from) }) + " are each waiting on a choice."))
        } else if let one = waiting.first {
            alerts.append((
                "\(name(one.from)) is ready to evolve",
                "Into \(one.options.map(name).joined(separator: " or ")). Pick one in PokeBar."))
        }
        return alerts + others
    }

    /// "A", "A and B", "A, B and C". No Oxford comma, and no em dash anywhere
    /// near it: this is user-facing copy.
    nonisolated static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// Asks for permission once there is a Pokemon to raise, and confirms.
    ///
    /// **Not lazy, and that was a bug before it was a decision.** Asking on the
    /// first postable event means the first evolution races the permission prompt,
    /// and a notification posted while authorization is still pending is dropped.
    /// The one event notifications exist for is the one that would be swallowed.
    /// Asking when the player first has something to raise settles permission
    /// hours before the first evolution can fire, at a moment they are already
    /// looking at the app.
    ///
    /// Still not asked at launch: a user who never touches the game half is never
    /// prompted.
    func requestIfNeeded() async {
        guard Self.isAvailable, authorized == nil else { return }
        guard await ensureAuthorized() else { return }

        // One confirmation, ever. It proves the delivery path end to end, which
        // otherwise cannot be known until an evolution happens to fire, and it
        // says plainly what will and will not interrupt the user.
        guard !UserDefaults.standard.bool(forKey: Self.confirmedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.confirmedKey)
        await deliver(
            title: "PokeBar notifications are on",
            body: "You will hear about evolutions, graduations and shinies. Nothing else.")
    }

    /// Posts whatever in `events` is worth interrupting for.
    ///
    /// A refusal is remembered for the run and never re-asked, and posting never
    /// triggers a prompt: if permission has not been settled yet the events are
    /// simply dropped, because a notification racing its own permission dialog
    /// does not arrive anyway.
    func post(_ events: [GameEvent], dex: Pokedex) async {
        guard Self.isAvailable, authorized == true else { return }
        for alert in Self.announcements(for: events, dex: dex) {
            await deliver(title: alert.title, body: alert.body)
        }
    }

    private func deliver(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func ensureAuthorized() async -> Bool {
        if let authorized { return authorized }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        authorized = granted
        return granted
    }
}
