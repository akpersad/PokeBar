import Foundation
import XCTest

/// Builds a throwaway `session-store.db` with the same `assistant_usage_events`
/// shape observed in the live `~/.copilot/session-store.db`.
///
/// Shared by `CopilotUsageParserTests` and `UsageMonitorTests` because both need
/// a real database, and two copies of a schema is two things that can drift from
/// what the CLI actually writes.
///
/// Built through the `sqlite3` CLI rather than the C API on purpose: fixture
/// creation and parsing then run on two independent code paths, so a bug shared
/// by both could not hide.
enum CopilotFixture {

    struct Row {
        var model: String
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
        var createdAt: String

        /// `input_tokens` is the whole request, cache classes included, which is
        /// what the live rows do: measured there, the remainder after both cache
        /// classes is 2 or 3 tokens.
        init(
            model: String = "claude-sonnet-5",
            input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0,
            createdAt: String = CopilotFixture.recentTimestamp()
        ) {
            self.model = model
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.createdAt = createdAt
        }
    }

    /// Relative to `Date()`, never a literal. `UsageLedger` prunes its in-flight
    /// dedup table against a 2 day window keyed on the *log* timestamp, so a
    /// hardcoded date stops working exactly 48 hours after it is written. That
    /// has already cost this repo one red suite.
    static func recentTimestamp(minutesAgo: Double = 1) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSinceNow: -minutesAgo * 60))
    }

    /// The full column list the real table carries, not just the seven the
    /// parser reads. A fixture trimmed to the columns under test could not catch
    /// the parser reaching for one that is not there.
    private static let createTable = """
        CREATE TABLE assistant_usage_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            turn_index INTEGER,
            agent_id TEXT,
            parent_tool_call_id TEXT,
            model TEXT NOT NULL,
            input_tokens INTEGER,
            output_tokens INTEGER,
            cache_read_tokens INTEGER,
            cache_write_tokens INTEGER,
            reasoning_tokens INTEGER,
            total_nano_aiu INTEGER,
            request_multiplier REAL,
            duration_ms INTEGER,
            time_to_first_token_ms INTEGER,
            inter_token_latency_ms INTEGER,
            initiator TEXT,
            api_endpoint TEXT,
            reasoning_effort TEXT,
            finish_reason TEXT,
            content_filter_triggered INTEGER,
            token_details_json TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            cwd TEXT,
            repository TEXT,
            host_type TEXT,
            branch TEXT,
            summary TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );
        """

    /// - Parameter reasoningTokens: written into every row. In the real data this
    ///   is a subset of `output_tokens`, so a parser that added it in as a fifth
    ///   class would over-count; a test can set it and assert the totals do not
    ///   move.
    @discardableResult
    /// - Parameter cwd: the working directory the fixture's session sits in, or
    ///   nil to leave the session row out entirely, which is the shape of a usage
    ///   row whose session has since been deleted.
    static func makeDatabase(
        at url: URL, rows: [Row], reasoningTokens: Int = 0,
        cwd: String? = "/Users/someone/Code/thing"
    ) throws -> URL {
        var sql = createTable + "\n"
        if let cwd {
            sql += "INSERT INTO sessions (id, cwd) VALUES ('s', '\(cwd)');\n"
        }
        for row in rows {
            sql += """
                INSERT INTO assistant_usage_events
                    (session_id, model, input_tokens, output_tokens,
                     cache_read_tokens, cache_write_tokens, reasoning_tokens, created_at)
                VALUES ('s', '\(row.model)', \(row.input), \(row.output),
                        \(row.cacheRead), \(row.cacheWrite), \(reasoningTokens),
                        '\(row.createdAt)');\n
                """
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "fixture database must build cleanly")
        return url
    }

    /// A path in the temporary directory that no file occupies yet.
    static func scratchURL(_ label: String = "copilot") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pokebar-\(label)-\(UUID().uuidString).db")
    }
}
