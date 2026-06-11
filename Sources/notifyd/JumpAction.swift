import AppKit
import NotifyCore

/// The user-facing "jump to this session" action, shared by the menu dropdown
/// and (Phase 3) the hotkey overlay: focus the tmux pane, then raise the GUI
/// terminal window hosting it.
@MainActor
enum JumpAction {
    @discardableResult
    static func jump(to session: PendingSession, bridge: TmuxBridge = TmuxBridge()) -> TmuxBridge.JumpResult {
        let socket = TmuxBridge.socketPath(from: session.tmuxSocket)
        let result = bridge.jump(paneId: session.paneId, windowId: session.windowId, socket: socket)
        if result == .ok {
            // Tier 1 terminal raise (no special permission needed).
            let pid = bridge.clientPid(forSession: session.tmuxSession, socket: socket)
            TerminalFocus.raise(clientPid: pid)
        }
        return result
    }
}
