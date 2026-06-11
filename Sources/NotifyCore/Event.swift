import Foundation

/// The current event schema version. The hook stamps every line with this; the
/// app skips any line whose `schema` it does not recognize (forward-compat).
public let currentSchema = 1

/// Logical classification of an event, derived by the hook from the raw Claude
/// Code `hook_event_name` / `notification_type`. The app reconciles on `kind`,
/// not on the raw event name, so the two stay decoupled.
public enum EventKind: String, Codable, Sendable {
    /// Claude is blocked on a permission prompt — highest priority.
    case permission
    /// Claude finished a turn / is idle waiting for the next prompt.
    case idle
    /// The user replied (UserPromptSubmit) or a session (re)started — drop pending.
    case clear
    /// The session ended — forget it entirely.
    case end
}

/// One line of `events.jsonl`. Decoding is deliberately lenient: only
/// `session_id` and `kind` are required to be useful; everything else is
/// optional context that may be empty when Claude is not running inside tmux or
/// when the pane has already gone away.
public struct Event: Codable, Sendable {
    public var schema: Int
    /// ISO-8601 timestamp string, as written by the hook. Kept as a string so a
    /// malformed value never fails decoding of an otherwise-good line.
    public var ts: String
    /// Raw Claude Code hook event name (Notification, Stop, …) — for debugging.
    public var event: String?
    public var kind: EventKind
    public var sessionId: String

    // tmux context, captured at event time.
    public var paneId: String?
    public var tmuxSocket: String?
    public var tmuxSession: String?
    public var windowId: String?
    public var windowIndex: String?
    public var clientTty: String?
    public var paneTitle: String?
    public var paneCmd: String?

    // Claude context.
    public var cwd: String?
    public var transcriptPath: String?
    public var message: String?
    public var title: String?

    enum CodingKeys: String, CodingKey {
        case schema, ts, event, kind
        case sessionId = "session_id"
        case paneId = "pane_id"
        case tmuxSocket = "tmux_socket"
        case tmuxSession = "tmux_session"
        case windowId = "window_id"
        case windowIndex = "window_index"
        case clientTty = "client_tty"
        case paneTitle = "pane_title"
        case paneCmd = "pane_cmd"
        case cwd
        case transcriptPath = "transcript_path"
        case message, title
    }

    /// `true` when this event references a real tmux pane we could jump to.
    public var hasPane: Bool {
        if let p = paneId, !p.isEmpty { return true }
        return false
    }
}
