import Foundation

/// Thin wrapper over the `tmux` CLI: enumerate live panes and focus a pane by id.
///
/// Every call passes `-S <socket>` so we address the exact server an event came
/// from (the user may run multiple tmux servers on different sockets). The
/// socket path is the first comma-separated field of `$TMUX` / the event's
/// `tmux_socket` (e.g. `/private/tmp/tmux-501/default,34372,0`).
public struct TmuxBridge {
    public let tmuxPath: String

    public init(tmuxPath: String = TmuxBridge.defaultTmuxPath()) {
        self.tmuxPath = tmuxPath
    }

    public static func defaultTmuxPath() -> String {
        for p in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return "tmux"
    }

    /// Extract the socket path from a `$TMUX`-style value (strip the trailing
    /// `,pid,session` fields). Returns nil for an empty/garbage value.
    public static func socketPath(from tmuxEnv: String?) -> String? {
        guard let v = tmuxEnv, !v.isEmpty else { return nil }
        let socket = v.split(separator: ",", maxSplits: 1).first.map(String.init) ?? v
        return socket.isEmpty ? nil : socket
    }

    // MARK: - Running tmux

    @discardableResult
    private func run(_ args: [String], socket: String?) -> (status: Int32, out: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxPath)
        var full: [String] = []
        if let socket { full += ["-S", socket] }
        full += args
        proc.arguments = full

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - Queries

    /// The set of live pane ids (`%NN`) across all sessions on the given socket.
    public func livePaneIds(socket: String?) -> Set<String> {
        let r = run(["list-panes", "-a", "-F", "#{pane_id}"], socket: socket)
        guard r.status == 0 else { return [] }
        return Set(r.out.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// `true` if a tmux server is reachable on the socket.
    public func serverRunning(socket: String?) -> Bool {
        run(["list-panes", "-a", "-F", "#{pane_id}"], socket: socket).status == 0
    }

    /// The shell pid backing a pane (`#{pane_pid}`), or nil if the pane is gone.
    public func panePid(_ paneId: String, socket: String?) -> Int32? {
        let r = run(["display-message", "-p", "-t", paneId, "#{pane_pid}"], socket: socket)
        guard r.status == 0 else { return nil }
        return Int32(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The pid of a client currently attached to `session`, if any. Used to walk
    /// the process tree up to the hosting terminal GUI. Returns the first client.
    public func clientPid(forSession session: String?, socket: String?) -> Int32? {
        guard let session, !session.isEmpty else { return nil }
        let r = run(["list-clients", "-t", session, "-F", "#{client_pid}"], socket: socket)
        guard r.status == 0 else { return nil }
        for line in r.out.split(whereSeparator: \.isNewline) {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) { return pid }
        }
        return nil
    }

    // MARK: - Navigation

    public enum JumpResult: Equatable {
        case ok
        case paneGone
        case noServer
        case missingPane          // event had no pane id (not in tmux)
    }

    /// Focus the given window+pane on the given socket. Uses `@`/`%` ids, which
    /// survive renames/renumbering. Returns whether the jump landed.
    @discardableResult
    public func jump(paneId: String?, windowId: String?, socket: String?) -> JumpResult {
        guard let paneId, !paneId.isEmpty else { return .missingPane }
        guard serverRunning(socket: socket) else { return .noServer }
        guard livePaneIds(socket: socket).contains(paneId) else { return .paneGone }

        if let windowId, !windowId.isEmpty {
            run(["select-window", "-t", windowId], socket: socket)
        }
        run(["select-pane", "-t", paneId], socket: socket)
        return .ok
    }
}
