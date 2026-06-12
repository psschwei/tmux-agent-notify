import Foundation
import Testing
@testable import NotifyCore

private func ev(_ kind: EventKind, _ sid: String, pane: String = "%1", ts: String = "t",
                gitBranch: String? = nil, gitDirty: String? = nil) -> Event {
    Event(schema: 1, ts: ts, event: nil, kind: kind, sessionId: sid,
          paneId: pane, tmuxSocket: "/s,1,0", tmuxSession: "0", windowId: "@1",
          windowIndex: "1", windowName: "main", clientTty: nil, paneTitle: nil, paneCmd: nil,
          cwd: "/x", transcriptPath: nil, message: nil, title: nil,
          gitBranch: gitBranch, gitDirty: gitDirty)
}

@Test func latestEventWins() {
    // idle then permission -> permission (blocking)
    let p = EventStore.reduce([ev(.idle, "a"), ev(.permission, "a")])
    #expect(p.count == 1)
    #expect(p[0].kind == .permission)
}

@Test func clearRemovesPending() {
    let p = EventStore.reduce([ev(.permission, "a"), ev(.clear, "a")])
    #expect(p.isEmpty)
}

@Test func endForgetsSession() {
    let p = EventStore.reduce([ev(.idle, "a"), ev(.end, "a")])
    #expect(p.isEmpty)
}

@Test func multipleSessionsPreserveOrder() {
    let p = EventStore.reduce([ev(.permission, "a"), ev(.idle, "b")])
    #expect(p.map(\.sessionId) == ["a", "b"])
}

@Test func reClearedThenPendingAgain() {
    // a session that was cleared then comes back idle should be pending again
    let p = EventStore.reduce([ev(.idle, "a"), ev(.clear, "a"), ev(.idle, "a")])
    #expect(p.count == 1)
    #expect(p[0].kind == .idle)
}

@Test func reduceCarriesGitContext() {
    let p = EventStore.reduce([ev(.idle, "a", gitBranch: "main", gitDirty: "1")])
    #expect(p.count == 1)
    #expect(p[0].gitBranch == "main")
    #expect(p[0].gitDirty == true)
    #expect(p[0].branchLabel == "main*")
}

@Test func reduceNoGitContext() {
    let p = EventStore.reduce([ev(.idle, "a")])
    #expect(p[0].gitDirty == false)
    #expect(p[0].branchLabel == nil)
}

@Test func parseSkipsUnknownSchema() {
    let line: Substring = Substring(#"{"schema":99,"ts":"t","kind":"idle","session_id":"a"}"#)
    #expect(EventStore.parseLine(line) == nil)
}

@Test func parseSkipsGarbage() {
    #expect(EventStore.parseLine("not json") == nil)
    #expect(EventStore.parseLine("") == nil)
}

@Test func tailingReadsAppendedLines() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("est-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let l1 = #"{"schema":1,"ts":"t","kind":"permission","session_id":"a","pane_id":"%1"}"#
    try (l1 + "\n").write(to: tmp, atomically: true, encoding: .utf8)

    let store = EventStore(url: tmp)
    var pending = store.refresh()
    #expect(pending.count == 1)

    // Append a second session, then a partial (incomplete) line.
    let fh = try FileHandle(forWritingTo: tmp)
    fh.seekToEndOfFile()
    fh.write(Data((#"{"schema":1,"ts":"t","kind":"idle","session_id":"b","pane_id":"%2"}"# + "\n").utf8))
    fh.write(Data(#"{"schema":1,"ts":"t","kind":"idle""#.utf8))  // no newline yet
    try fh.close()

    pending = store.refresh()
    #expect(pending.count == 2)            // partial line not yet counted

    // Complete the partial line; it should now be parsed and counted.
    let fh2 = try FileHandle(forWritingTo: tmp)
    fh2.seekToEndOfFile()
    fh2.write(Data((#","session_id":"c","pane_id":"%3"}"# + "\n").utf8))
    try fh2.close()

    pending = store.refresh()
    #expect(pending.count == 3)
}

@Test func tailingDetectsTruncation() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("est-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let big = (1...3).map { #"{"schema":1,"ts":"t","kind":"idle","session_id":"s\#($0)","pane_id":"%\#($0)"}"# }
        .joined(separator: "\n") + "\n"
    try big.write(to: tmp, atomically: true, encoding: .utf8)
    let store = EventStore(url: tmp)
    #expect(store.refresh().count == 3)

    // Truncate/rewrite to a single session — store should rebuild, not double-count.
    try (#"{"schema":1,"ts":"t","kind":"permission","session_id":"only","pane_id":"%9"}"# + "\n")
        .write(to: tmp, atomically: true, encoding: .utf8)
    let after = store.refresh()
    #expect(after.count == 1)
    #expect(after[0].sessionId == "only")
}
