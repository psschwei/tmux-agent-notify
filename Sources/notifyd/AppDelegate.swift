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
    /// Latest pending set, kept fresh by `reload()` so the overlay opens instantly.
    private var pending: [PendingSession] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensureBaseDir()
        status = StatusController()
        overlay = OverlayController(pendingProvider: { [weak self] in self?.pending ?? [] })

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
    }
}
