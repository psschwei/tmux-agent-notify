import AppKit
import Foundation

/// Raises the GUI terminal application hosting tmux, so that after we move the
/// tmux active pane the right window is actually visible.
///
/// Tier 1 (implemented here) needs NO special permission: identify the host
/// terminal by walking the process tree up from the tmux client pid, then
/// `NSRunningApplication.activate`. This is sufficient for the common
/// single-window case. Tier 2 (per-window AppleScript, requires Automation TCC)
/// is deferred to Phase 3 behind a flag.
enum TerminalFocus {

    /// Known terminal emulators, matched by the executable/process name we find
    /// while walking up the process tree, mapped to their bundle identifiers.
    private static let knownTerminals: [(needle: String, bundleId: String)] = [
        ("iTermServer", "com.googlecode.iterm2"),
        ("iTerm", "com.googlecode.iterm2"),
        ("Terminal", "com.apple.Terminal"),
        ("ghostty", "com.mitchellh.ghostty"),
        ("kitty", "net.kovidgoyal.kitty"),
        ("wezterm", "com.github.wez.wezterm"),
        ("alacritty", "org.alacritty"),
    ]

    /// Walk up from `pid` via `ps -o ppid=,comm=` until we hit a known terminal.
    /// Returns its bundle id, or nil if none matched before reaching pid 1.
    static func hostBundleId(forClientPid pid: Int32) -> String? {
        var current = pid
        var hops = 0
        while current > 1 && hops < 40 {
            guard let (ppid, comm) = psParent(of: current) else { return nil }
            for t in knownTerminals where comm.contains(t.needle) {
                return t.bundleId
            }
            current = ppid
            hops += 1
        }
        return nil
    }

    /// One `ps` lookup: returns (parent pid, command name) for a pid.
    private static func psParent(of pid: Int32) -> (Int32, String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "ppid=,comm=", "-p", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        // Format: "<ppid> <comm...>" — comm may contain spaces/path.
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first, let ppid = Int32(first) else { return nil }
        let comm = parts.count > 1 ? String(parts[1]) : ""
        return (ppid, comm)
    }

    /// Tier 1: activate the host terminal app (raises its windows). Returns true
    /// if we found and activated a known terminal. `clientPid` comes from
    /// `tmux list-clients -F '#{client_pid}'` for the target session, when known.
    @discardableResult
    static func raise(clientPid: Int32?) -> Bool {
        var bundleId: String?
        if let clientPid { bundleId = hostBundleId(forClientPid: clientPid) }
        // Fallback: if we couldn't resolve via the client pid, try the frontmost
        // known terminal that is already running.
        let candidates: [NSRunningApplication]
        if let bundleId {
            candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        } else {
            candidates = NSWorkspace.shared.runningApplications.filter { app in
                guard let bid = app.bundleIdentifier else { return false }
                return knownTerminals.contains { $0.bundleId == bid }
            }
        }
        guard let app = candidates.first else { return false }
        return app.activate(options: [.activateAllWindows])
    }
}
