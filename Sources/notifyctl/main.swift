import Foundation
import NotifyCore

// notifyctl — CLI for inspecting pending sessions and exercising the tmux jump.
// Used as the Phase 1 vertical slice (validates pane correlation without any GUI)
// and as a debugging tool thereafter.
//
//   notifyctl              list pending sessions
//   notifyctl list         same
//   notifyctl jump <id>    focus the tmux pane for session <id> (prefix match ok)

func homeRowKeys() -> [String] {
    "a s d f g h j k l ; q w e r t y u i o p".split(separator: " ").map(String.init)
}

func loadPending(includeDead: Bool = false) -> [PendingSession] {
    let store = EventStore()
    var pending = store.refresh()
    // By default, drop sessions whose pane no longer runs a Claude process and
    // collapse to one entry per pane.
    if !includeDead {
        pending = LivenessChecker().liveCollapsed(pending)
    }
    // Blocking (permission) first, then idle; stable within group.
    return pending.sorted { ($0.isBlocking ? 0 : 1) < ($1.isBlocking ? 0 : 1) }
}

func printList(_ pending: [PendingSession]) {
    if pending.isEmpty {
        print("No sessions need attention.")
        return
    }
    let keys = homeRowKeys()
    let bridge = TmuxBridge()
    for (i, s) in pending.enumerated() {
        let key = i < keys.count ? keys[i] : "·"
        let kindStr = s.isBlocking ? "PERMISSION" : "idle"
        let loc: String
        if let sess = s.tmuxSession, let win = s.windowIndex, !sess.isEmpty {
            loc = "\(sess):\(win)"
        } else {
            loc = "(no tmux)"
        }
        // Staleness: does the pane still exist on its socket?
        var staleMark = ""
        if let pane = s.paneId, !pane.isEmpty {
            let socket = TmuxBridge.socketPath(from: s.tmuxSocket)
            if !bridge.livePaneIds(socket: socket).contains(pane) {
                staleMark = " [stale: pane gone]"
            }
        }
        let dir = s.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
        let msg = (s.title ?? s.message ?? "").replacingOccurrences(of: "\n", with: " ")
        let msgTrunc = msg.count > 50 ? String(msg.prefix(50)) + "…" : msg
        print("[\(key)] \(loc)  \(kindStr)  \(dir)  \(s.sessionId.prefix(8))\(staleMark)")
        if !msgTrunc.isEmpty { print("     \(msgTrunc)") }
    }
}

func jump(toPrefix prefix: String, _ pending: [PendingSession]) -> Int32 {
    let matches = pending.filter { $0.sessionId.hasPrefix(prefix) }
    guard let s = matches.first else {
        FileHandle.standardError.write(Data("No pending session matching '\(prefix)'.\n".utf8))
        return 1
    }
    if matches.count > 1 {
        FileHandle.standardError.write(Data("Ambiguous prefix '\(prefix)' (\(matches.count) matches).\n".utf8))
        return 1
    }
    let bridge = TmuxBridge()
    let socket = TmuxBridge.socketPath(from: s.tmuxSocket)
    let result = bridge.jump(paneId: s.paneId, windowId: s.windowId, socket: socket)
    switch result {
    case .ok:          print("Jumped to \(s.tmuxSession ?? "?"):\(s.windowIndex ?? "?") pane \(s.paneId ?? "?")"); return 0
    case .paneGone:    FileHandle.standardError.write(Data("Pane \(s.paneId ?? "?") no longer exists.\n".utf8)); return 2
    case .noServer:    FileHandle.standardError.write(Data("No tmux server on that socket.\n".utf8)); return 3
    case .missingPane: FileHandle.standardError.write(Data("Session has no tmux pane (not in tmux).\n".utf8)); return 4
    }
}

// --- dispatch ---
let args = Array(CommandLine.arguments.dropFirst())
let includeDead = args.contains("--all")
let pending = loadPending(includeDead: includeDead)

switch args.first {
case nil, "list", "--all":
    printList(pending)
case "jump":
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("usage: notifyctl jump <session-id-prefix>\n".utf8))
        exit(64)
    }
    exit(jump(toPrefix: args[1], pending))
default:
    FileHandle.standardError.write(Data("usage: notifyctl [list | jump <session-id-prefix>]\n".utf8))
    exit(64)
}
