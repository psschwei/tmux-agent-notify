import AppKit
import SwiftUI
import NotifyCore

/// Borderless, non-activating panel that shows the home-row jump list. It can
/// become key (to receive keystrokes) WITHOUT activating the app, so the
/// terminal stays foreground and focus returns cleanly after a jump.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    private var panel: KeyablePanel?
    private var keyMonitor: Any?
    private var rows: [OverlayRow] = []
    private let bridge = TmuxBridge()
    private let keys = "asdfghjkl;qwertyuiop".map { String($0) }

    /// Source of the current pending set (the app's EventStore-backed reload).
    private let pendingProvider: @MainActor () -> [PendingSession]

    init(pendingProvider: @escaping @MainActor () -> [PendingSession]) {
        self.pendingProvider = pendingProvider
    }

    /// Toggle: if open, close; otherwise build from the latest pending set and show.
    func toggle() {
        if panel != nil { close(); return }
        show()
    }

    private func show() {
        let pending = pendingProvider()
            .sorted { ($0.isBlocking ? 0 : 1) < ($1.isBlocking ? 0 : 1) }
        rows = buildRows(pending)

        let view = OverlayView(rows: rows)
        let hosting = NSHostingView(rootView: view)
        hosting.layout()
        let size = hosting.fittingSize

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting
        center(panel)

        // Local key monitor: single keypress resolves a row (or esc closes).
        // The monitor fires on the main thread; we read keyCode/characters here
        // (value types) and hop to the main actor to act, swallowing the event.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let chars = event.charactersIgnoringModifiers
            MainActor.assumeIsolated { self?.handleKey(keyCode: keyCode, chars: chars) }
            return nil   // swallow all keys while the overlay is up
        }

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private func buildRows(_ pending: [PendingSession]) -> [OverlayRow] {
        // Compute staleness once per socket.
        var stale: Set<String> = []
        var bySocket: [String?: [String]] = [:]
        for s in pending {
            guard let p = s.paneId, !p.isEmpty else { continue }
            bySocket[TmuxBridge.socketPath(from: s.tmuxSocket), default: []].append(p)
        }
        for (socket, panes) in bySocket {
            let live = bridge.livePaneIds(socket: socket)
            for p in panes where !live.contains(p) { stale.insert(p) }
        }
        return pending.enumerated().map { i, s in
            OverlayRow(id: s.sessionId,
                       key: i < keys.count ? keys[i] : "·",
                       session: s,
                       stale: s.paneId.map { stale.contains($0) } ?? false)
        }
    }

    private func handleKey(keyCode: UInt16, chars: String?) {
        if keyCode == 53 { close(); return }                      // esc
        guard let chars, !chars.isEmpty else { return }
        if let row = rows.first(where: { $0.key == chars }) {
            if !row.stale { JumpAction.jump(to: row.session) }
            close()
        }
        // other keys: ignored (already swallowed by the monitor)
    }

    private func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let s = panel.frame.size
        let origin = NSPoint(x: vf.midX - s.width / 2,
                             y: vf.midY - s.height / 2 + vf.height * 0.12)
        panel.setFrameOrigin(origin)
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
