import Foundation

/// User configuration, read from `~/.claude-tmux-notify/config.json`. Absent or
/// malformed file → defaults. Kept tiny and forgiving on purpose.
///
/// Example:
/// ```json
/// { "hotkey": { "key": "j", "modifiers": ["cmd", "option"] } }
/// ```
public struct Config: Codable, Sendable {
    public struct Hotkey: Codable, Sendable {
        /// Single character of the trigger key, e.g. "j", "space" (or " ").
        public var key: String
        /// Any of: cmd, option/alt, control/ctrl, shift.
        public var modifiers: [String]

        public init(key: String, modifiers: [String]) {
            self.key = key
            self.modifiers = modifiers
        }
    }

    public var hotkey: Hotkey

    public init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    /// Default: ⌥⌘J.
    public static let `default` = Config(hotkey: Hotkey(key: "j", modifiers: ["cmd", "option"]))

    /// Load from the standard path, falling back to defaults on any problem.
    public static func load(from url: URL = Paths.configFile) -> Config {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(Config.self, from: data)
        else { return .default }
        return cfg
    }
}
