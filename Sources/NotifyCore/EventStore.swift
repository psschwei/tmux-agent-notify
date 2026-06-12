import Foundation

/// A session that currently needs attention, as derived from the event log.
public struct PendingSession: Identifiable, Sendable {
    public var id: String { sessionId }
    public let sessionId: String
    public let kind: EventKind          // .permission or .idle
    public let paneId: String?
    public let windowId: String?
    public let tmuxSocket: String?
    public let tmuxSession: String?
    public let windowIndex: String?
    public let windowName: String?
    public let clientTty: String?
    public let cwd: String?
    public let message: String?
    public let title: String?
    public let ts: String
    public let gitBranch: String?
    public let gitDirty: Bool

    /// True if blocking (permission prompt) — sorts/colors ahead of idle.
    public var isBlocking: Bool { kind == .permission }

    /// cwd with a `$HOME` prefix collapsed to `~`. "?" when cwd is absent.
    public var abbreviatedPath: String {
        guard let p = cwd else { return "?" }
        let home = NSHomeDirectory()
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }

    /// "branch" or "branch*" (dirty), or nil when not in a git repo.
    public var branchLabel: String? {
        guard let b = gitBranch, !b.isEmpty else { return nil }
        return gitDirty ? b + "*" : b
    }

    /// The tmux window name, or nil when not running inside tmux / name absent.
    public var windowLabel: String? {
        guard let n = windowName, !n.isEmpty else { return nil }
        return n
    }
}

/// Reconciles the append-only event log into the current pending set.
///
/// Reconciliation is a pure function of the event sequence (`reduce`), so it is
/// trivially unit-testable. `EventStore` adds incremental file tailing on top.
public final class EventStore {

    // MARK: - Pure reconciliation

    /// Fold a sequence of events into the pending set. File order is authority:
    /// the latest event for a session wins. `clear`/`end` remove it.
    public static func reduce<S: Sequence>(_ events: S) -> [PendingSession] where S.Element == Event {
        // Preserve first-seen order for stable display when ts ties.
        var order: [String] = []
        var latest: [String: Event] = [:]
        for e in events {
            if latest[e.sessionId] == nil { order.append(e.sessionId) }
            latest[e.sessionId] = e
        }
        var result: [PendingSession] = []
        for sid in order {
            guard let e = latest[sid] else { continue }
            switch e.kind {
            case .permission, .idle:
                result.append(PendingSession(
                    sessionId: e.sessionId, kind: e.kind, paneId: e.paneId,
                    windowId: e.windowId, tmuxSocket: e.tmuxSocket,
                    tmuxSession: e.tmuxSession, windowIndex: e.windowIndex,
                    windowName: e.windowName,
                    clientTty: e.clientTty, cwd: e.cwd, message: e.message,
                    title: e.title, ts: e.ts,
                    gitBranch: e.gitBranch, gitDirty: (e.gitDirty?.isEmpty == false)))
            case .clear, .end:
                continue
            }
        }
        return result
    }

    /// Parse one JSONL line into an Event, or nil if it is blank, malformed, or
    /// carries an unrecognized schema (forward-compat: skip the unknown).
    public static func parseLine(_ line: Substring) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let e = try? JSONDecoder().decode(Event.self, from: data),
              e.schema == currentSchema
        else { return nil }
        return e
    }

    // MARK: - Incremental tailing

    private let url: URL
    private var offset: UInt64 = 0
    private var inode: UInt64 = 0
    private var partial = ""               // buffered incomplete trailing line
    private var events: [Event] = []       // all events parsed so far

    public init(url: URL = Paths.eventsFile) {
        self.url = url
    }

    /// Read everything (cold start) or only new bytes since the last call, and
    /// return the freshly-reconciled pending set. Detects truncation/rotation
    /// (size shrank or inode changed) and rebuilds from scratch.
    @discardableResult
    public func refresh() -> [PendingSession] {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            // File absent yet — nothing pending.
            return EventStore.reduce(events)
        }
        let size = (attrs[.size] as? UInt64) ?? 0
        let curInode = (attrs[.systemFileNumber] as? UInt64) ?? 0

        if curInode != inode || size < offset {
            // Rotated or truncated: rebuild.
            offset = 0; partial = ""; events.removeAll(); inode = curInode
        }

        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return EventStore.reduce(events)
        }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        let newData = fh.readDataToEndOfFile()
        offset += UInt64(newData.count)

        if !newData.isEmpty {
            var chunk = partial + String(decoding: newData, as: UTF8.self)
            // If the chunk does not end in a newline, hold back the last line.
            if !chunk.hasSuffix("\n") {
                if let idx = chunk.lastIndex(of: "\n") {
                    partial = String(chunk[chunk.index(after: idx)...])
                    chunk = String(chunk[...idx])
                } else {
                    partial = chunk
                    chunk = ""
                }
            } else {
                partial = ""
            }
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
                if let e = EventStore.parseLine(line) { events.append(e) }
            }
        }
        return EventStore.reduce(events)
    }

    /// Default size past which `compactIfNeeded` rewrites the log.
    public static let compactThreshold: UInt64 = 5 * 1024 * 1024   // 5 MB

    /// If the log has grown past `threshold`, rewrite it to a compact snapshot:
    /// one `idle`/`permission` line per currently-pending session (everything
    /// else — clears, ends, history — is dropped). The hook only ever appends,
    /// so the app is the sole compactor; we hold the same lock the hook uses.
    ///
    /// Returns true if a compaction happened. Safe to call on every refresh.
    @discardableResult
    public func compactIfNeeded(threshold: UInt64 = EventStore.compactThreshold) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > threshold
        else { return false }

        // Snapshot the current pending set from in-memory state.
        let pending = EventStore.reduce(events)
        let lines = pending.compactMap { snapshotLine(for: $0) }
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")

        // Acquire the shared lock, then atomically replace the file. We use the
        // POSIX lock on a sidecar so we coordinate with the hook's `flock`.
        let lockFD = open(Paths.lockFile.path, O_CREAT | O_RDWR, 0o644)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }

        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        // We just rewrote the file: reset tailing state so the next refresh
        // reads our snapshot cleanly (atomic write changes the inode).
        offset = 0; partial = ""; events.removeAll(); inode = 0
        _ = refresh()
        return true
    }

    /// Re-encode a pending session as a single JSONL line (schema-compatible).
    private func snapshotLine(for s: PendingSession) -> String? {
        let e = Event(
            schema: currentSchema, ts: s.ts, event: "Compact", kind: s.kind,
            sessionId: s.sessionId, paneId: s.paneId, tmuxSocket: s.tmuxSocket,
            tmuxSession: s.tmuxSession, windowId: s.windowId, windowIndex: s.windowIndex,
            windowName: s.windowName,
            clientTty: s.clientTty, paneTitle: nil, paneCmd: nil, cwd: s.cwd,
            transcriptPath: nil, message: s.message, title: s.title,
            gitBranch: s.gitBranch, gitDirty: s.gitDirty ? "1" : "")
        guard let data = try? JSONEncoder().encode(e) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
