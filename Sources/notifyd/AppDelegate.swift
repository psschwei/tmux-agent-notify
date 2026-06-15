import AppKit
import Carbon.HIToolbox
import NotifyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusController!
    private let store = EventStore()
    private var watcher: LogWatcher!
    private var hotKey: HotKey!
    private var overlay: OverlayController!
    private let presenter = NotificationPresenter()
    /// Notification preferences, read once at launch.
    private var notifyConfig = Config.Notifications()
    /// Last seen kind per session id, to fire banners only on a *new* prompt
    /// (newly pending) or an escalation (idle → permission), not every reload.
    private var lastKind: [String: NotifyCore.EventKind] = [:]
    /// Latest pending set, kept fresh by `reload()` so the overlay opens instantly.
    private var pending: [PendingSession] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensureBaseDir()
        status = StatusController()
        presenter.start()
        overlay = OverlayController(pendingProvider: { [weak self] in self?.pending ?? [] })

        // Dismissal: both the menu and the overlay append a `.clear` event via
        // the shared store, then reload so the entry drops immediately.
        status.onClear = { [weak self] s in self?.store.clear(s); self?.reload() }
        status.onClearAll = { [weak self] in
            guard let self else { return }
            self.store.clearAll(self.pending)
            self.reload()
        }
        overlay.onClear = { [weak self] s in self?.store.clear(s); self?.reload() }

        // React to log changes (from the watcher and the menu's Refresh).
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .logChanged, object: nil)

        watcher = LogWatcher(file: Paths.eventsFile) { [weak self] in
            self?.reload()
        }
        watcher.start()

        // Global hotkey toggles the jump overlay. Read from config, falling back
        // to ⌥⌘J if the configured combo is missing/invalid.
        let cfg = Config.load()
        notifyConfig = cfg.notifications
        let spec = HotKeySpec.resolve(cfg.hotkey)
            ?? (UInt32(kVK_ANSI_J), UInt32(optionKey | cmdKey))
        hotKey = HotKey(keyCode: spec.0, modifiers: spec.1) { [weak self] in
            self?.overlay.toggle()
        }

        reload()   // initial cold-start read
    }

    private let liveness = LivenessChecker()

    @objc private func reload() {
        let raw = store.refresh()
        // Keep the append-only log from growing without bound over time.
        store.compactIfNeeded()
        // Filter out sessions whose pane no longer runs a Claude process (crashed
        // session or pane reused as a plain shell), and collapse to one entry per
        // pane so a lingering old session_id can't double up with the current one.
        pending = liveness.liveCollapsed(raw)
        status.update(pending: pending)
        presenter.updatePending(pending)
        fireNotifications()
    }

    /// Diff the current pending set against the last seen kinds and pop a banner
    /// for anything newly needing attention or escalating idle → permission.
    private func fireNotifications() {
        var seen: [String: NotifyCore.EventKind] = [:]
        for s in pending {
            seen[s.sessionId] = s.kind
            let prior = lastKind[s.sessionId]
            // New prompt, or escalation from idle to a blocking permission.
            let isNew = prior == nil
            let escalated = prior == .idle && s.kind == .permission
            if (isNew || escalated) && notifyConfig.enabled(for: s.kind) {
                presenter.notify(s)
            }
        }
        // Drop sessions that are no longer pending so they can re-notify later.
        lastKind = seen
    }
}
