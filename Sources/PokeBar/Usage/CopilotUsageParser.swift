import Foundation
import SQLite3

/// Reads `assistant_usage_events` from `~/.copilot/session-store.db`.
///
/// Unlike Claude Code and Codex, Copilot CLI logs to a live SQLite database
/// (WAL mode), not append-only JSONL, and rows are never rewritten in place.
/// Verified against a live session on this machine: the first row credited
/// (`id = 8`, 44036 input tokens) read back identically 40+ minutes and ten
/// more rows later. A Claude Code turn is rewritten ~2.4 times as it streams,
/// which is why *that* parser needs keep-max dedup; a Copilot row is written
/// once, after the request finishes, so dedup here only needs a cursor on the
/// monotonic `id` column.
///
/// Global, not scoped to this repository: `sessions.cwd` would let this be
/// filtered to PokeBar's checkout the way the file-tree sources effectively
/// are, but the decision here (see DECISIONS.md) is to count all Copilot CLI
/// usage on the machine, the same way Claude Code and Codex are not filtered
/// to "sessions opened inside PokeBar" either.
enum CopilotUsageParser {

    /// Default location, matching the CLI's own path. Overridable so tests can
    /// point at a fixture database instead of the real one.
    static func defaultDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configured = environment["COPILOT_CLI_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured).appendingPathComponent("session-store.db")
        }
        return home.appendingPathComponent(".copilot/session-store.db")
    }

    struct Result: Sendable, Equatable {
        var entries: [UsageEntry] = []
        /// Highest `id` seen, to persist as the next call's `cursor`. Equal to
        /// the input `cursor` when nothing new was found.
        var cursor: Int64
    }

    /// How long to wait out a transient lock. A read-only WAL reader is not
    /// blocked by a writer, but the shared-memory index can be briefly busy
    /// while it is being initialised or recovered, and the alternative to
    /// waiting 100ms is skipping this tick's rows until the next write happens
    /// to fire the watcher again.
    private static let busyTimeoutMilliseconds: Int32 = 100

    /// Reads every `assistant_usage_events` row with `id > cursor`.
    ///
    /// Opened read-only, so a concurrent CLI write under WAL is never blocked
    /// or corrupted by this process, and a machine that has never run Copilot
    /// CLI (no database file) returns nothing rather than creating one.
    ///
    /// A read-only connection still needs to *create* the `-shm` index file if
    /// no other process currently holds the database open, which is why this
    /// takes the containing directory's write permission for granted: it is the
    /// user's own `~/.copilot`. Never `immutable=1`, which would skip the WAL
    /// entirely; measured here, the main database file was 4 KiB against a
    /// 3.4 MiB WAL, so ignoring the WAL means reading essentially nothing.
    static func scan(databaseURL: URL = defaultDatabaseURL(), cursor: Int64) -> Result {
        // A missing database is the ordinary state of a machine that has never
        // run Copilot CLI, so it is silent. Every failure *past* this point is
        // reported instead, because the visible symptom of one is Copilot usage
        // that simply never appears: exactly the silent-failure shape this
        // project keeps getting bitten by.
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return Result(cursor: cursor)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db
        else {
            report("could not open \(databaseURL.lastPathComponent)", db)
            sqlite3_close(db)
            return Result(cursor: cursor)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, busyTimeoutMilliseconds)

        let sql = """
            SELECT id, model, input_tokens, output_tokens,
                   cache_read_tokens, cache_write_tokens, created_at
            FROM assistant_usage_events
            WHERE id > ?
            ORDER BY id
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            report("could not read assistant_usage_events", db)
            sqlite3_finalize(statement)
            return Result(cursor: cursor)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cursor)

        var entries: [UsageEntry] = []
        var maxID = cursor
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }

            // The cursor advances past every row this loop *sees*, including
            // ones skipped below. A row that cannot be parsed is skipped
            // permanently rather than re-read forever: wedging the cursor on
            // one bad row would stop every later row from ever being credited.
            let rowID = sqlite3_column_int64(statement, 0)
            maxID = max(maxID, rowID)

            guard let modelText = sqlite3_column_text(statement, 1),
                  let createdText = sqlite3_column_text(statement, 6),
                  let date = timestamp(String(cString: createdText))
            else { continue }

            let input = sqlite3_column_int64(statement, 2)
            let output = sqlite3_column_int64(statement, 3)
            let cacheRead = sqlite3_column_int64(statement, 4)
            let cacheWrite = sqlite3_column_int64(statement, 5)

            // `input_tokens` reports the whole request, cache classes included
            // (the same shape Codex's `input_tokens` uses), so ordinary input
            // is the remainder after both cache classes are removed. Measured
            // over 108 live rows: the remainder is 2 or 3 on every one and
            // never negative, so the clamp is a guard, not load-bearing.
            //
            // `reasoning_tokens` is deliberately *not* added in. It is a subset
            // of `output_tokens`, not a fifth class: over the same 108 rows no
            // row has reasoning > output, and the row's own
            // `token_details_json` prices input, cache read, cache write and
            // output only, with no reasoning line. Adding it would double-count
            // thinking tokens and mint coins for them twice.
            let tokens = TokenCounts(
                input: max(0, Int(input) - Int(cacheRead) - Int(cacheWrite)),
                output: Int(output),
                cacheWrite: Int(cacheWrite),
                cacheRead: Int(cacheRead))
            guard tokens.total > 0 else { continue }

            entries.append(UsageEntry(
                id: "copilot|\(rowID)",
                date: date,
                model: String(cString: modelText),
                source: .copilotCLI,
                tokens: tokens,
                localDay: ClaudeUsageParser.localDayKey(date)))
        }

        if step != SQLITE_DONE {
            // Mid-read failure. The cursor still advances to the highest row
            // actually seen, and that loses nothing: `ORDER BY id` means the
            // rows read form a contiguous prefix, so everything unread is
            // still `> maxID` and arrives on the next tick. Advancing is also
            // the safe direction. A cursor left where it was would re-offer
            // these same rows on every tick, and once they age past the
            // ledger's 2 day growth window a re-offer is credited a second
            // time, which coins are frozen against ever undoing.
            report("stopped part-way through assistant_usage_events", db)
        }
        return Result(entries: entries, cursor: maxID)
    }

    // MARK: - Helpers

    /// `created_at` is written by the CLI as `2026-08-24T15:08:10.375Z` on all
    /// 108 rows measured here, which `ClaudeUsageParser` already parses. The
    /// fallback covers the column's own schema default, `datetime('now')`,
    /// which yields `2026-08-24 15:08:10`: UTC, space-separated, no zone
    /// marker. That default has never fired in practice, but a row this cannot
    /// parse is skipped *permanently*, because the cursor moves past it, so the
    /// three lines are worth it.
    ///
    /// Normalised into ISO and handed to the same parser rather than given a
    /// `DateFormatter` of its own: a formatter is a reference type and would
    /// need synchronising to sit here as a static under Swift 6, which is a
    /// lot of machinery for a format that has never actually appeared.
    static func timestamp(_ raw: String) -> Date? {
        if let date = ClaudeUsageParser.parseTimestamp(raw) { return date }
        guard raw.count == 19, raw.contains(" ") else { return nil }
        return ClaudeUsageParser.parseTimestamp(
            raw.replacingOccurrences(of: " ", with: "T") + "Z")
    }

    /// Loud, because the alternative is Copilot usage that quietly never
    /// arrives. Matches how `GameMonitor` reports an unreadable save: this app
    /// has no log subsystem, and one line on stderr is what gets read.
    private static func report(_ what: String, _ db: OpaquePointer?) {
        let detail = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "no detail"
        print("PokeBar: Copilot usage \(what): \(detail)")
    }
}
