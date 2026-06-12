import SwiftUI
import NotifyCore

/// One row in the overlay: a home-row key + session summary.
struct OverlayRow: Identifiable {
    let id: String              // sessionId
    let key: String             // "a", "s", …
    let session: PendingSession
    let stale: Bool

    var location: String {
        if let s = session.tmuxSession, let w = session.windowIndex, !s.isEmpty {
            return "\(s):\(w)"
        }
        return "no-tmux"
    }
    var dir: String { session.abbreviatedPath }
    var branch: String? { session.branchLabel }
    var window: String? { session.windowLabel }
    var note: String {
        (session.title ?? session.message ?? "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Secondary line: path, optional `⎇ branch`, optional `— note`.
    var subtitle: String {
        var s = dir
        if let b = branch { s += " ⎇ \(b)" }
        if !note.isEmpty { s += " — \(note)" }
        return s
    }
}

/// The overlay content: a compact list of pending sessions, each bound to a
/// home-row key. Pressing the key is handled by the panel (a local key monitor),
/// not here — this view is purely presentational so it stays simple.
struct OverlayView: View {
    let rows: [OverlayRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "bell.badge.fill")
                Text("Sessions needing attention")
                    .font(.headline)
                Spacer()
                Text("esc")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            if rows.isEmpty {
                Text("Nothing pending")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 12) {
                        Text(row.key)
                            .font(.system(.body, design: .monospaced).weight(.bold))
                            .frame(width: 22, height: 22)
                            .background(row.stale ? Color.gray.opacity(0.2)
                                                  : (row.session.isBlocking ? Color.red.opacity(0.25)
                                                                            : Color.accentColor.opacity(0.2)))
                            .clipShape(RoundedRectangle(cornerRadius: 5))

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(row.location)
                                    .font(.system(.body, design: .monospaced))
                                if let w = row.window {
                                    Text(w)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                if row.session.isBlocking {
                                    Text("permission").font(.caption).foregroundStyle(.red)
                                } else {
                                    Text("idle").font(.caption).foregroundStyle(.secondary)
                                }
                                if row.stale {
                                    Text("pane gone").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Text(row.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .opacity(row.stale ? 0.5 : 1)
                }
            }
        }
        .frame(width: 380)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
