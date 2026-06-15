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

    /// When true, a home-row key dismisses that session instead of jumping. The
    /// user toggles this with `-` while the overlay is up; reset on each open.
    private var clearMode = false

    /// Source of the current pending set (the app's EventStore-backed reload).
    private let pendingProvider: @MainActor () -> [PendingSession]

    /// Dismiss a session (append `.clear`). Set by the app; shared with the menu.
    var onClear: ((PendingSession) -> Void)?

    init(pendingProvider: @escaping @MainActor () -> [PendingSession]) {
        self.pendingProvider = pendingProvider
    }

    /// Toggle: if open, close; otherwise build from the latest pending set and show.
    func toggle() {
        if panel != nil { close(); return }
        show()
    }

    private func show() {
        clearMode = false
        let pending = pendingProvider()
            .sorted { ($0.isBlocking ? 0 : 1) < ($1.isBlocking ? 0 : 1) }
        rows = buildRows(pending)

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: .zero),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        installContent()
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

        panel.makeKeyAndOrderFront(nil)
    }

    /// Build the SwiftUI content for the current `rows` / `clearMode` and install
    /// it on the panel, resizing the panel to fit. Called on show and on every
    /// mode toggle so the header and key-chip tint update live.
    private func installContent() {
        guard let panel else { return }
        let hosting = NSHostingView(rootView: OverlayView(rows: rows, clearMode: clearMode))
        hosting.layout()
        let size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(size)
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
        // `-` toggles clear mode in place (don't close): keys then dismiss
        // instead of jumping.
        if chars == "-" {
            clearMode.toggle()
            installContent()
            return
        }
        guard let chars, !chars.isEmpty else { return }
        if let row = rows.first(where: { $0.key == chars }) {
            if clearMode {
                if !row.stale { onClear?(row.session) }
            } else {
                if !row.stale { JumpAction.jump(to: row.session) }
            }
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
