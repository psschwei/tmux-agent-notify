import Foundation

/// A snapshot of the process table, used to answer "is a Claude Code process
/// running underneath this pane's shell?" — the signal that a pending event
/// still corresponds to a live agent (rather than a plain shell prompt left
/// behind after the session crashed or the pane was reused).
///
/// We shell out to `ps` (not `pgrep`, which can be filtered in restricted
/// contexts) and parse pid/ppid/comm once, then answer queries in-memory.
public struct ProcessTree {
    /// pid -> parent pid
    private let parent: [Int32: Int32]
    /// pid -> command name (`comm`, e.g. "claude", "zsh")
    private let comm: [Int32: String]

    public init?(psOutput: String? = nil) {
        let text: String
        if let psOutput {
            text = psOutput
        } else {
            guard let out = ProcessTree.runPS() else { return nil }
            text = out
        }
        var parent: [Int32: Int32] = [:]
        var comm: [Int32: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            // Format: "<pid> <ppid> <comm...>" — comm is the trailing remainder.
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            parent[pid] = ppid
            comm[pid] = parts[2...].joined(separator: " ")
        }
        guard !parent.isEmpty else { return nil }
        self.parent = parent
        self.comm = comm
    }

    private static func runPS() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// True if any process whose `comm`'s last path component is `name` has
    /// `ancestor` somewhere in its parent chain (inclusive of direct children).
    public func hasDescendant(named name: String, under ancestor: Int32) -> Bool {
        for (pid, c) in comm where commMatches(c, name) {
            if isDescendant(pid, of: ancestor) { return true }
        }
        return false
    }

    private func commMatches(_ comm: String, _ name: String) -> Bool {
        // `comm` may be a bare name ("claude") or a path; match the leaf.
        let leaf = comm.split(separator: "/").last.map(String.init) ?? comm
        return leaf == name
    }

    private func isDescendant(_ pid: Int32, of ancestor: Int32) -> Bool {
        var cur = pid
        var hops = 0
        while hops < 64 {
            if cur == ancestor { return true }
            guard let p = parent[cur], p != cur else { return false }
            if p <= 1 { return false }
            cur = p
            hops += 1
        }
        return false
    }
}
