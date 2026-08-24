import XCTest

@testable import PokeBar

/// The dated copy of `game-state.json` taken before the save is read.
///
/// The quarantine path already covers a save that will not decode. This covers
/// the one that decodes and is wrong, which is what a migration can produce, so
/// the assertions here are about *when* a copy is taken and which copies survive
/// rather than about the bytes.
final class SaveBackupTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
        super.tearDown()
    }

    /// A directory with, optionally, a save already in it.
    private func makeSave(contents: String? = "{\"coinsSpent\":0}") throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokebar-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        scratch.append(base)
        let stateURL = base.appendingPathComponent("game-state.json")
        if let contents { try Data(contents.utf8).write(to: stateURL) }
        return stateURL
    }

    private func backupNames(for stateURL: URL) throws -> [String] {
        let directory = stateURL.deletingLastPathComponent()
            .appendingPathComponent("backups")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .sorted()
    }

    private func day(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.date(from: "\(iso)T12:00:00\(offsetSuffix)")!
    }

    /// Noon local, so the day stamp is unambiguous whatever the machine's zone.
    private var offsetSuffix: String {
        let seconds = TimeZone.current.secondsFromGMT()
        if seconds == 0 { return "Z" }
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return String(format: "%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }

    // MARK: - Capturing

    func testABackupIsWrittenWhenASaveExists() throws {
        let stateURL = try makeSave(contents: "{\"dust\":7}")

        let written = SaveBackup(stateURL: stateURL).capture(on: day("2026-08-24"))

        XCTAssertEqual(try backupNames(for: stateURL), ["game-state-2026-08-24.json"])
        XCTAssertEqual(
            try String(decoding: Data(contentsOf: XCTUnwrap(written)), as: UTF8.self),
            "{\"dust\":7}",
            "the copy is byte for byte, not a re-encode")
    }

    /// A fresh install has nothing to protect, and an empty backups directory
    /// full of empty files would be indistinguishable from a wiped collection.
    func testNothingIsWrittenWhenThereIsNoSave() throws {
        let stateURL = try makeSave(contents: nil)

        XCTAssertNil(SaveBackup(stateURL: stateURL).capture(on: day("2026-08-24")))
        XCTAssertEqual(try backupNames(for: stateURL), [])
    }

    /// **The first capture of a day wins.** This is the half of the design that
    /// makes the backup useful against a bad write rather than only against a
    /// crash: today's copy is the save as it stood before today ran, so a launch
    /// that corrupts the save cannot then overwrite the copy that would have
    /// undone it.
    func testASecondLaunchTheSameDayDoesNotOverwriteTheCopy() throws {
        let stateURL = try makeSave(contents: "{\"good\":true}")
        let backup = SaveBackup(stateURL: stateURL)
        let first = try XCTUnwrap(backup.capture(on: day("2026-08-24")))

        // A bad write, then another launch on the same day.
        try Data("{}".utf8).write(to: stateURL)
        let second = backup.capture(on: day("2026-08-24"))

        XCTAssertEqual(second, first, "same day, same file")
        XCTAssertEqual(
            try String(decoding: Data(contentsOf: first), as: UTF8.self),
            "{\"good\":true}",
            "the good copy survived the bad write")
        XCTAssertEqual(try backupNames(for: stateURL).count, 1)
    }

    // MARK: - Pruning

    /// Ten days of launches all survive; the eleventh evicts the oldest, and it
    /// evicts by *day*, not by count of launches. Several launches a day is the
    /// normal case for a menu bar app and must not cost history.
    func testTheEleventhDayPrunesTheOldest() throws {
        let stateURL = try makeSave()
        let backup = SaveBackup(stateURL: stateURL)

        for offset in 0..<10 {
            // Three launches each day, to prove the count that matters is days.
            for _ in 0..<3 {
                backup.capture(on: day(String(format: "2026-08-%02d", offset + 1)))
            }
        }
        XCTAssertEqual(try backupNames(for: stateURL).count, SaveBackup.keep)
        XCTAssertEqual(try backupNames(for: stateURL).first, "game-state-2026-08-01.json")

        backup.capture(on: day("2026-08-11"))

        let names = try backupNames(for: stateURL)
        XCTAssertEqual(names.count, SaveBackup.keep, "still capped")
        XCTAssertEqual(names.first, "game-state-2026-08-02.json", "the oldest day went")
        XCTAssertEqual(names.last, "game-state-2026-08-11.json", "today is present")
    }

    /// Sorting is on the name, so the eviction order has to hold across a month
    /// and a year boundary where lexical order is the only thing that is true.
    func testPruningOrdersByDayNotByWhenTheCopyWasTaken() throws {
        let stateURL = try makeSave()
        let backup = SaveBackup(stateURL: stateURL)

        // Written newest first, so modification order is the reverse of day order.
        for iso in ["2027-01-03", "2027-01-02", "2027-01-01", "2026-12-31"]
            + (4...10).map { String(format: "2027-01-%02d", $0) }
        {
            backup.capture(on: day(iso))
        }
        XCTAssertEqual(try backupNames(for: stateURL).count, SaveBackup.keep)

        backup.capture(on: day("2027-01-11"))

        let names = try backupNames(for: stateURL)
        XCTAssertFalse(
            names.contains("game-state-2026-12-31.json"),
            "the oldest day goes even though it was not the first file written")
        XCTAssertTrue(names.contains("game-state-2027-01-11.json"))
    }

    /// The quarantine file lives beside the save, not in `backups/`, and is not
    /// a dated copy. Pruning must not count it or delete it.
    func testTheQuarantineFileIsNotTreatedAsABackup() throws {
        let stateURL = try makeSave()
        let quarantine = stateURL.deletingPathExtension()
            .appendingPathExtension("unreadable.json")
        try Data("{\"corrupt\":".utf8).write(to: quarantine)

        SaveBackup(stateURL: stateURL).capture(on: day("2026-08-24"))

        XCTAssertEqual(try backupNames(for: stateURL), ["game-state-2026-08-24.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
    }
}

/// The wiring, which is the part that can silently do nothing.
@MainActor
final class GameMonitorBackupTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
        super.tearDown()
    }

    private func makeStateURL() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokebar-monitor-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        scratch.append(base)
        return base.appendingPathComponent("game-state.json")
    }

    private func backups(for stateURL: URL) throws -> [String] {
        let directory = stateURL.deletingLastPathComponent()
            .appendingPathComponent("backups")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testLaunchingWithASaveBacksItUp() throws {
        let stateURL = try makeStateURL()
        let saved = """
            {"coinsSpent":300,"inventory":{},"hasShinyCharm":false,"dust":4,
             "log":{"events":[]}}
            """
        try Data(saved.utf8).write(to: stateURL)

        _ = GameMonitor(dex: nil, stateURL: stateURL)

        XCTAssertEqual(try backups(for: stateURL).count, 1)
        let copy = stateURL.deletingLastPathComponent()
            .appendingPathComponent("backups")
            .appendingPathComponent(try XCTUnwrap(backups(for: stateURL).first))
        XCTAssertEqual(
            try String(decoding: Data(contentsOf: copy), as: UTF8.self), saved,
            "the copy is the save as it was before the launch read it")
    }

    func testAFirstLaunchWritesNoBackup() throws {
        let stateURL = try makeStateURL()

        _ = GameMonitor(dex: nil, stateURL: stateURL)

        XCTAssertEqual(try backups(for: stateURL), [])
    }

    /// The existing quarantine still fires, and the backup is taken as well:
    /// they cover different failures and neither replaces the other.
    func testACorruptSaveIsBothBackedUpAndQuarantined() throws {
        let stateURL = try makeStateURL()
        try Data("{\"log\":".utf8).write(to: stateURL)

        _ = GameMonitor(dex: nil, stateURL: stateURL)

        XCTAssertEqual(try backups(for: stateURL).count, 1, "backed up before the read")
        let quarantine = stateURL.deletingPathExtension()
            .appendingPathExtension("unreadable.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: quarantine.path),
            "and still quarantined by the existing path")
    }
}
