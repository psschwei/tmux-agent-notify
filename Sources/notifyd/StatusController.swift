import AppKit
import NotifyCore

/// Owns the menu-bar item: a count badge plus a dropdown listing pending
/// sessions, each clickable to jump. This is the reliable, permission-free
/// fallback UI (the hotkey overlay in Phase 3 is the fast path).
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let bridge = TmuxBridge()
    private var pending: [PendingSession] = []
    /// Pane ids that no longer exist (stale) — refreshed when the menu opens.
    private var stalePanes: Set<String> = []

    /// Home-row labels reused from the overlay design, shown as menu key hints.
    private let keys = "asdfghjkl;qwertyuiop".map { String($0) }

    /// Dismiss one session / all sessions. Set by the app; both append a
    /// `.clear` event via the shared `EventStore` and trigger a reload.
    var onClear: ((PendingSession) -> Void)?
    var onClearAll: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render()
    }

    /// Update the cached pending set and redraw the button. Called by the app on
    /// every log change.
    func update(pending: [PendingSession]) {
        // Blocking (permission) first, then idle.
        self.pending = pending.sorted { ($0.isBlocking ? 0 : 1) < ($1.isBlocking ? 0 : 1) }
        render()
    }

    // MARK: - Button

    private func render() {
        guard let button = statusItem.button else { return }
        let count = pending.count
        let blocking = pending.contains(where: \.isBlocking)
        let symbol = blocking ? "eye.fill" : "eye"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude sessions")
        button.image = img
        button.imagePosition = .imageLeading
        button.title = count == 0 ? "" : " \(count)"
        // Red tint when something is blocking on a permission prompt.
        button.contentTintColor = blocking ? .systemRed : nil
    }

    // MARK: - Menu (built lazily when opened)

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStaleness()
        menu.removeAllItems()

        if pending.isEmpty {
            let none = NSMenuItem(title: "No sessions need attention", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for (i, s) in pending.enumerated() {
                menu.addItem(sessionItem(s, index: i))
                menu.addItem(clearItem(s))
            }
        }

        menu.addItem(.separator())
        let clearAll = NSMenuItem(title: "Clear All", action: #selector(clearAllSessions), keyEquivalent: "")
        clearAll.target = self
        clearAll.isEnabled = !pending.isEmpty
        menu.addItem(clearAll)
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open events.jsonl", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
    }

    private func sessionItem(_ s: PendingSession, index: Int) -> NSMenuItem {
        let keyHint = index < keys.count ? keys[index] : "·"
        let loc: String
        if let sess = s.tmuxSession, let win = s.windowIndex, !sess.isEmpty {
            loc = "\(sess):\(win)"
        } else {
            loc = "no-tmux"
        }
        let kind = s.isBlocking ? "⛔︎ permission" : "· idle"
        let stale = (s.paneId.map { stalePanes.contains($0) } ?? false)
        var title = "[\(keyHint)]  \(loc)  \(kind)"
        if let w = s.windowLabel { title += "  \(w)" }
        if stale { title += "  (pane gone)" }

        let item = NSMenuItem(title: title, action: #selector(jumpTo(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = s
        item.isEnabled = !stale && s.paneId != nil
        if let msg = (s.title ?? s.message), !msg.isEmpty {
            item.toolTip = msg
        }
        return item
    }

    /// An ⌥-alternate of the session row: holding Option turns the row into a
    /// "Clear" action that dismisses the notification instead of jumping. This
    /// keeps the plain click on `sessionItem` as the jump fast-path.
    private func clearItem(_ s: PendingSession) -> NSMenuItem {
        let item = NSMenuItem(title: "Clear notification", action: #selector(clearSession(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = s
        item.isAlternate = true
        item.keyEquivalentModifierMask = .option
        return item
    }

    private func refreshStaleness() {
        // Group pending panes by socket, query live panes once per socket.
        stalePanes.removeAll()
        var bySocket: [String?: [String]] = [:]
        for s in pending {
            guard let pane = s.paneId, !pane.isEmpty else { continue }
            bySocket[TmuxBridge.socketPath(from: s.tmuxSocket), default: []].append(pane)
        }
        for (socket, panes) in bySocket {
            let live = bridge.livePaneIds(socket: socket)
            for p in panes where !live.contains(p) { stalePanes.insert(p) }
        }
    }

    // MARK: - Actions

    @objc private func jumpTo(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? PendingSession else { return }
        JumpAction.jump(to: s)
    }

    @objc private func clearSession(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? PendingSession else { return }
        onClear?(s)
    }

    @objc private func clearAllSessions() {
        onClearAll?()
    }

    @objc private func refresh() {
        NotificationCenter.default.post(name: .logChanged, object: nil)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Paths.eventsFile)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let logChanged = Notification.Name("tmuxAgentNotify.logChanged")
}
