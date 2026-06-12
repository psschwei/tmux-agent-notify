import Foundation

/// Why a pending session might not be actionable.
public enum Liveness: Sendable {
    case live          // pane exists and a `claude` process runs under it
    case paneGone      // the tmux pane no longer exists
    case noAgent       // pane exists but no Claude process — a bare shell now
    case notTmux       // event had no pane (Claude wasn't in tmux)
}

/// Classifies pending sessions by whether a live Claude Code process still backs
/// them. This is what filters out panes that merely *used* to run an agent (the
/// session crashed or the pane was reused as a plain shell) — events that never
/// got a clean `clear`/`end`.
public struct LivenessChecker {
    private let bridge: TmuxBridge
    /// Process name to look for under the pane shell. Claude's process `comm` is
    /// "claude" (stable across versions, unlike tmux's pane_current_command which
    /// shows the version string).
    private let agentProcessName: String

    public init(bridge: TmuxBridge = TmuxBridge(), agentProcessName: String = "claude") {
        self.bridge = bridge
        self.agentProcessName = agentProcessName
    }

    /// Classify one session. `tree` is a shared process snapshot (take one per
    /// batch to avoid spawning `ps` per session).
    public func classify(_ s: PendingSession, tree: ProcessTree?) -> Liveness {
        guard let pane = s.paneId, !pane.isEmpty else { return .notTmux }
        let socket = TmuxBridge.socketPath(from: s.tmuxSocket)
        guard bridge.livePaneIds(socket: socket).contains(pane) else { return .paneGone }
        guard let tree, let pid = bridge.panePid(pane, socket: socket) else {
            // Can't inspect processes — fail open (assume live) rather than hide
            // a real pending session.
            return .live
        }
        return tree.hasDescendant(named: agentProcessName, under: pid) ? .live : .noAgent
    }

    /// True when the session's transcript has advanced *past* the pending event's
    /// timestamp — i.e. Claude produced output after it said it needed attention,
    /// so the attention was already given and the entry is stale.
    ///
    /// Claude Code emits no hook when a turn resumes (e.g. after approving a
    /// permission prompt), so a `permission`/`idle` entry would otherwise linger
    /// until the next `UserPromptSubmit`. The transcript file's mtime is the
    /// resume signal we can read without a hook.
    ///
    /// Fails closed: a missing/unreadable transcript or an unparseable timestamp
    /// returns `false` (keep the session) so we never hide a real prompt.
    /// Strictly-greater so a `Stop` that wrote the transcript in the same second
    /// it fired is kept.
    public func transcriptAdvanced(_ s: PendingSession) -> Bool {
        guard let path = s.transcriptPath, !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date
        else { return false }
        let fmt = ISO8601DateFormatter()
        guard let eventDate = fmt.date(from: s.ts) else { return false }
        return mtime > eventDate
    }

    /// Keep only sessions still backed by a live agent (or non-tmux, which we
    /// can't verify and so keep). Drops `paneGone` and `noAgent`, and drops any
    /// session whose transcript advanced past its event (resumed/busy → stale).
    public func liveOnly(_ pending: [PendingSession]) -> [PendingSession] {
        let tree = ProcessTree()
        return pending.filter {
            switch classify($0, tree: tree) {
            case .live, .notTmux:
                return !transcriptAdvanced($0)
            case .paneGone, .noAgent:
                return false
            }
        }
    }

    /// Like `liveOnly`, but additionally collapses to ONE entry per tmux pane —
    /// since a pane hosts at most one Claude process, multiple pending
    /// session_ids on the same pane mean an old session lingered. Keep the
    /// newest (by `ts`). Non-tmux sessions are passed through unchanged (keyed
    /// by their own session_id). Input order is otherwise preserved.
    public func liveCollapsed(_ pending: [PendingSession]) -> [PendingSession] {
        let live = liveOnly(pending)
        var byPane: [String: PendingSession] = [:]   // paneId -> chosen session
        var result: [PendingSession] = []            // preserves first-seen order
        var paneSlot: [String: Int] = [:]            // paneId -> index in result

        for s in live {
            guard let pane = s.paneId, !pane.isEmpty else {
                result.append(s)                      // non-tmux: never collapsed
                continue
            }
            if let existing = byPane[pane] {
                // Keep the newer event for this pane; on equal timestamps prefer
                // a blocking (permission) event over idle.
                let prefer = s.ts > existing.ts
                    || (s.ts == existing.ts && s.isBlocking && !existing.isBlocking)
                if prefer, let idx = paneSlot[pane] {
                    byPane[pane] = s
                    result[idx] = s
                }
            } else {
                byPane[pane] = s
                paneSlot[pane] = result.count
                result.append(s)
            }
        }
        return result
    }
}
