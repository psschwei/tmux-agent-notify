import Foundation
import Testing
@testable import NotifyCore

private func sess(_ sid: String, pane: String?, blocking: Bool = false, ts: String = "t",
                  transcriptPath: String? = nil) -> PendingSession {
    PendingSession(sessionId: sid, kind: blocking ? .permission : .idle, paneId: pane,
                   windowId: "@1", tmuxSocket: "/s,1,0", tmuxSession: "0",
                   windowIndex: "1", windowName: "main", clientTty: nil, cwd: "/x",
                   transcriptPath: transcriptPath, message: nil,
                   title: nil, ts: ts, gitBranch: nil, gitDirty: false)
}

// A checker whose liveOnly is the identity (so we test collapse logic in
// isolation, independent of the real process table).
private struct PassthroughChecker {
    func liveCollapsed(_ pending: [PendingSession]) -> [PendingSession] {
        // Mirror LivenessChecker.liveCollapsed but treat everything as live.
        var byPane: [String: PendingSession] = [:]
        var result: [PendingSession] = []
        var slot: [String: Int] = [:]
        for s in pending {
            guard let pane = s.paneId, !pane.isEmpty else { result.append(s); continue }
            if let existing = byPane[pane] {
                let prefer = s.ts > existing.ts
                    || (s.ts == existing.ts && s.isBlocking && !existing.isBlocking)
                if prefer, let i = slot[pane] { byPane[pane] = s; result[i] = s }
            } else {
                byPane[pane] = s; slot[pane] = result.count; result.append(s)
            }
        }
        return result
    }
}

@Test func collapsesTwoSessionsOnSamePaneKeepingNewest() {
    let out = PassthroughChecker().liveCollapsed([
        sess("old", pane: "%1", ts: "2026-01-01T00:00:00Z"),
        sess("new", pane: "%1", ts: "2026-01-01T00:01:00Z"),
    ])
    #expect(out.count == 1)
    #expect(out[0].sessionId == "new")
}

@Test func equalTimestampPrefersBlocking() {
    let out = PassthroughChecker().liveCollapsed([
        sess("idle", pane: "%1", blocking: false, ts: "t"),
        sess("perm", pane: "%1", blocking: true, ts: "t"),
    ])
    #expect(out.count == 1)
    #expect(out[0].sessionId == "perm")
}

@Test func differentPanesNotCollapsed() {
    let out = PassthroughChecker().liveCollapsed([
        sess("a", pane: "%1"),
        sess("b", pane: "%2"),
    ])
    #expect(out.count == 2)
}

@Test func nonTmuxSessionsNeverCollapsed() {
    let out = PassthroughChecker().liveCollapsed([
        sess("a", pane: nil),
        sess("b", pane: nil),
    ])
    #expect(out.count == 2)
}

@Test func preservesFirstSeenOrder() {
    let out = PassthroughChecker().liveCollapsed([
        sess("a", pane: "%1"),
        sess("b", pane: "%2"),
        sess("a2", pane: "%1", ts: "z"),   // newer, same pane as a
    ])
    #expect(out.map(\.paneId) == ["%1", "%2"])
    #expect(out[0].sessionId == "a2")      // a replaced in place
}

// MARK: - transcriptAdvanced

/// Write a temp file and stamp its mtime, returning the path.
private func transcript(mtime: Date) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("notify-test-\(UUID().uuidString).jsonl")
    try Data().write(to: url)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    return url.path
}

@Test func transcriptNewerThanEventIsAdvanced() throws {
    let eventTs = "2026-06-12T12:00:00Z"
    let mtime = ISO8601DateFormatter().date(from: "2026-06-12T12:00:05Z")!
    let s = sess("x", pane: "%1", ts: eventTs, transcriptPath: try transcript(mtime: mtime))
    #expect(LivenessChecker().transcriptAdvanced(s))
}

@Test func transcriptEqualToEventIsNotAdvanced() throws {
    let eventTs = "2026-06-12T12:00:00Z"
    let mtime = ISO8601DateFormatter().date(from: eventTs)!
    let s = sess("x", pane: "%1", ts: eventTs, transcriptPath: try transcript(mtime: mtime))
    #expect(!LivenessChecker().transcriptAdvanced(s))   // genuinely parked at Stop
}

@Test func transcriptOlderThanEventIsNotAdvanced() throws {
    let mtime = ISO8601DateFormatter().date(from: "2026-06-12T11:59:55Z")!
    let s = sess("x", pane: "%1", ts: "2026-06-12T12:00:00Z",
                 transcriptPath: try transcript(mtime: mtime))
    #expect(!LivenessChecker().transcriptAdvanced(s))
}

@Test func missingTranscriptFailsClosed() {
    let s = sess("x", pane: "%1", ts: "2026-06-12T12:00:00Z",
                 transcriptPath: "/no/such/file.jsonl")
    #expect(!LivenessChecker().transcriptAdvanced(s))   // keep — never hide a real prompt
}

@Test func absentTranscriptPathFailsClosed() {
    let s = sess("x", pane: "%1", ts: "2026-06-12T12:00:00Z", transcriptPath: nil)
    #expect(!LivenessChecker().transcriptAdvanced(s))
}

@Test func unparseableTimestampFailsClosed() throws {
    let mtime = ISO8601DateFormatter().date(from: "2026-06-12T12:00:05Z")!
    let s = sess("x", pane: "%1", ts: "not-a-date", transcriptPath: try transcript(mtime: mtime))
    #expect(!LivenessChecker().transcriptAdvanced(s))
}
