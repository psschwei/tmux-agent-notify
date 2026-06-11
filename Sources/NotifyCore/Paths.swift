import Foundation

/// Filesystem locations shared by the hook, the CLI, and the menu-bar app.
///
/// Everything lives under `~/.claude-tmux-notify/`. The directory is created
/// lazily by whoever writes first (the hook creates it; the app tolerates its
/// absence until the first event arrives).
public enum Paths {
    /// `~/.claude-tmux-notify`
    public static var baseDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude-tmux-notify", isDirectory: true)
    }

    /// Append-only event log written by the hook, tailed by the app.
    public static var eventsFile: URL {
        baseDir.appendingPathComponent("events.jsonl", isDirectory: false)
    }

    /// Lock file guarding concurrent appends/compaction (`flock`).
    public static var lockFile: URL {
        baseDir.appendingPathComponent("events.jsonl.lock", isDirectory: false)
    }

    /// Optional user config (hotkey, …).
    public static var configFile: URL {
        baseDir.appendingPathComponent("config.json", isDirectory: false)
    }

    /// Create the base directory if it does not exist. Idempotent.
    @discardableResult
    public static func ensureBaseDir() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: baseDir, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}
