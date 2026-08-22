import Foundation

/// Chunked, newline-delimited reader for append-only logs.
///
/// Two constraints drive the design:
///
/// 1. **Bounded memory.** `~/.claude/projects` is 528 MB across 1,029 files.
///    Reading whole files was a real upstream defect (their commit 7a7149f,
///    "bound memory while parsing large Codex rollouts"), so we never hold more
///    than one chunk plus one line.
/// 2. **Resumable.** Claude Code appends to the *live* session file while we
///    read it. `read` returns the offset just past the last **complete** line,
///    so a half-written trailing line is left for the next pass instead of being
///    parsed as truncated JSON and dropped.
enum JSONLStreamer {
    /// 256 KB. Large enough that syscall overhead is irrelevant across 1,029
    /// files, small enough that peak RSS stays flat regardless of file size.
    static let chunkSize = 1 << 18

    enum StreamError: Error {
        case unreadable(URL)
    }

    /// Invokes `body` once per complete line starting at `offset`.
    /// - Returns: the byte offset immediately after the last complete line.
    ///   Feed it back in on the next call to read only what was appended since.
    @discardableResult
    static func read(
        _ url: URL,
        from offset: UInt64 = 0,
        onLine body: (String) throws -> Void
    ) throws -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw StreamError.unreadable(url)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var consumed = offset
        var pending = Data()

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            // Emit every complete line in `pending`, keeping the remainder.
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<nl]
                // +1 for the newline itself, so the offset lands on the next line.
                consumed += UInt64(lineData.count + 1)
                pending.removeSubrange(pending.startIndex...nl)
                guard !lineData.isEmpty,
                      let line = String(data: lineData, encoding: .utf8) else { continue }
                try body(line)
            }
        }
        // `pending` now holds a trailing fragment with no newline. Deliberately
        // discarded and not counted in `consumed`: either the file ends without
        // a newline (nothing lost, we re-read it next pass and it is still
        // incomplete) or a write is in flight (we get it once it completes).
        return consumed
    }
}
