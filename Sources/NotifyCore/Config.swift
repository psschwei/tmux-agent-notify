import Foundation

/// User configuration, read from `~/.claude-tmux-notify/config.json`. Absent or
/// malformed file → defaults. Kept tiny and forgiving on purpose.
///
/// Example:
/// ```json
/// {
///   "hotkey": { "key": "j", "modifiers": ["cmd", "option"] },
///   "notifications": { "permission": true, "idle": false }
/// }
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

    /// Which kinds of pending session should pop a native macOS banner. A
    /// missing key defaults to enabled, so an empty/absent block notifies on
    /// everything — opt out per kind, not in.
    public struct Notifications: Codable, Sendable {
        /// Banner when a session blocks on a permission prompt.
        public var permission: Bool
        /// Banner when a session finishes a turn / goes idle.
        public var idle: Bool

        public init(permission: Bool = true, idle: Bool = true) {
            self.permission = permission
            self.idle = idle
        }

        enum CodingKeys: String, CodingKey { case permission, idle }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.permission = (try? c.decodeIfPresent(Bool.self, forKey: .permission)) ?? nil ?? true
            self.idle = (try? c.decodeIfPresent(Bool.self, forKey: .idle)) ?? nil ?? true
        }

        /// Should a session of this kind fire a banner?
        public func enabled(for kind: EventKind) -> Bool {
            switch kind {
            case .permission: return permission
            case .idle: return idle
            case .clear, .end: return false
            }
        }
    }

    public var hotkey: Hotkey
    public var notifications: Notifications

    public init(hotkey: Hotkey, notifications: Notifications = Notifications()) {
        self.hotkey = hotkey
        self.notifications = notifications
    }

    enum CodingKeys: String, CodingKey { case hotkey, notifications }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hotkey = (try? c.decodeIfPresent(Hotkey.self, forKey: .hotkey)) ?? nil
            ?? Config.default.hotkey
        self.notifications = (try? c.decodeIfPresent(Notifications.self, forKey: .notifications)) ?? nil
            ?? Notifications()
    }

    /// Default: ⌥⌘J, notify on both permission and idle.
    public static let `default` = Config(
        hotkey: Hotkey(key: "j", modifiers: ["cmd", "option"]),
        notifications: Notifications())

    /// Load from the standard path, falling back to defaults on any problem.
    public static func load(from url: URL = Paths.configFile) -> Config {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(Config.self, from: data)
        else { return .default }
        return cfg
    }
}
