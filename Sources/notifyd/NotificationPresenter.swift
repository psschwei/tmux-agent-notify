import AppKit
import NotifyCore
import UserNotifications

/// Posts native macOS banners when a session newly needs attention, and jumps
/// to the right pane when the user clicks one.
///
/// Delivery requires a bundled, code-signed app (ours is ad-hoc signed and run
/// from `~/Applications`, which satisfies `UNUserNotificationCenter`). Which
/// kinds fire is driven by `Config.Notifications`.
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    /// Latest pending set, so a banner click can resolve its session and jump.
    private var pending: [PendingSession] = []
    /// True once the user has responded to the auth prompt and granted alerts.
    private var authorized = false

    func start() {
        center.delegate = self
        // The completion handler runs on a background queue, so it must be
        // non-isolated (@Sendable) — otherwise Swift inserts a main-actor
        // executor assertion that traps when it fires off-main. Hop explicitly.
        center.requestAuthorization(options: [.alert, .sound]) { @Sendable [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// Refresh the set used to resolve banner clicks. Called on every reload.
    func updatePending(_ pending: [PendingSession]) {
        self.pending = pending
    }

    /// Post a banner for a session that just started needing attention.
    func notify(_ s: PendingSession) {
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = Self.headline(for: s)
        if let body = (s.title ?? s.message), !body.isEmpty {
            content.body = body
        }
        // Permission prompts are blocking — make them audible.
        content.sound = s.isBlocking ? .default : nil
        content.userInfo = ["sessionId": s.sessionId]

        // Identify by session so a re-fire (idle → permission) replaces rather
        // than stacks. Immediate delivery (nil trigger).
        let req = UNNotificationRequest(
            identifier: s.sessionId, content: content, trigger: nil)
        center.add(req)
    }

    /// "session:window ⛔︎ permission" / "session:window · idle".
    private static func headline(for s: PendingSession) -> String {
        let loc: String
        if let sess = s.tmuxSession, let win = s.windowIndex, !sess.isEmpty {
            loc = "\(sess):\(win)"
        } else {
            loc = "no-tmux"
        }
        let kind = s.isBlocking ? "⛔︎ permission" : "· idle"
        if let w = s.windowLabel { return "\(loc)  \(kind)  \(w)" }
        return "\(loc)  \(kind)"
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even when our (agent) app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Click → jump to the pane, if the session is still pending.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["sessionId"] as? String
        // Ack the system synchronously; the jump itself hops to the main actor.
        completionHandler()
        Task { @MainActor in
            if let id, let s = self.pending.first(where: { $0.sessionId == id }) {
                JumpAction.jump(to: s)
            }
        }
    }
}
