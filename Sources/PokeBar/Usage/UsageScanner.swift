import Foundation

/// Per-file read position, persisted between launches.
///
/// `inode` is the rotation guard. Matching on path alone is not enough: if a
/// file is replaced (session archived, project moved) the path can stay
/// identical while the contents reset, and resuming at a stale byte offset would
/// silently skip every new turn.
struct FileCursor: Sendable, Equatable, Codable {
    var inode: UInt64
    var size: UInt64
    var offset: UInt64
}

/// Walks the Claude Code project tree and turns appended lines into entries.
///
/// The upstream design re-scanned on a 1 to 15 minute `Timer`, softened by an
/// mtime window. That is 528 MB of repeated work to answer a question whose
/// answer only changes when a file is written. Here the scanner is a pure
/// function of (roots, cursors) and something else decides when to call it, so
/// the same code serves both a cold start and an FSEvents notification.
struct UsageScanner: Sendable {

    struct Result: Sendable {
        /// Deduped entries discovered in this pass.
        var entries: [UsageEntry] = []
        /// Cursors to persist and feed into the next pass.
        var cursors: [String: FileCursor] = [:]
        var filesExamined = 0
        var filesRead = 0
        var bytesRead: UInt64 = 0
    }

    /// Default is `~/.claude/projects`. `CLAUDE_CONFIG_DIR` relocates the whole
    /// Claude config tree, and upstream had a live bug where the hardcoded path
    /// was consulted anyway, so we honour it.
    static func defaultRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return [URL(fileURLWithPath: configured).appendingPathComponent("projects")]
        }
        return [home.appendingPathComponent(".claude/projects")]
    }

    var roots: [URL]

    init(roots: [URL] = UsageScanner.defaultRoots()) {
        self.roots = roots
    }

    /// Reads everything appended since `cursors` and returns new entries.
    ///
    /// Dedup runs across the whole pass rather than per file, because the same
    /// `(message.id, requestId)` genuinely appears in multiple files when a
    /// session is resumed or forked.
    func scan(cursors previous: [String: FileCursor] = [:]) -> Result {
        var result = Result()
        var raw: [UsageEntry] = []

        for root in roots {
            for file in Self.jsonlFiles(under: root) {
                result.filesExamined += 1
                let path = file.path
                guard let stat = Self.stat(file) else { continue }

                var start: UInt64 = 0
                if let old = previous[path], old.inode == stat.inode, stat.size >= old.size {
                    // Same file, only grown: resume where we stopped.
                    start = old.offset
                } // else: replaced or truncated, re-read from zero.

                guard stat.size > start else {
                    // Nothing appended. Carry the cursor forward untouched.
                    result.cursors[path] = FileCursor(
                        inode: stat.inode, size: stat.size, offset: start)
                    continue
                }

                var consumed = start
                // Counts every line seen in this file, so an id-less line gets a
                // genuinely unique fallback key. Using the byte offset here would
                // not work: the offset is only advanced after the read returns.
                var lineIndex = 0
                do {
                    consumed = try JSONLStreamer.read(file, from: start) { line in
                        lineIndex += 1
                        // Cheap prefilter. Most lines in these files are not
                        // assistant turns, and skipping the JSON parse for them
                        // is the difference between a fast scan and a slow one.
                        guard line.contains("\"usage\"") else { return }
                        if let entry = ClaudeUsageParser.entry(
                            fromLine: line, fallbackID: "\(path)#\(start)+\(lineIndex)") {
                            raw.append(entry)
                        }
                    }
                } catch {
                    // Unreadable file (permissions, vanished mid-scan). Skip it
                    // without poisoning the cursor for the rest of the pass.
                    continue
                }

                result.filesRead += 1
                result.bytesRead += consumed - start
                result.cursors[path] = FileCursor(
                    inode: stat.inode, size: stat.size, offset: consumed)
            }
        }

        result.entries = ClaudeUsageParser.dedupKeepMax(raw)
        return result
    }

    // MARK: - Filesystem

    static func jsonlFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var out: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            out.append(url)
        }
        return out
    }

    /// Real inode via `systemFileNumber`, not `fileResourceIdentifierKey`.
    /// The latter is documented as opaque and its `hash` is only stable within a
    /// single process run, which is useless for a cursor we persist across
    /// launches: every restart would look like a rotation and force a full
    /// 528 MB re-read.
    private static func stat(_ url: URL) -> (inode: UInt64, size: UInt64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber
        else { return nil }
        return (inode.uint64Value, size.uint64Value)
    }
}
