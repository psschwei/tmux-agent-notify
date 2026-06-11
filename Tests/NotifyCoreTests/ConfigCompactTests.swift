import Foundation
import Testing
@testable import NotifyCore

@Test func configDefaultsWhenMissing() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("no-such-\(UUID().uuidString).json")
    let cfg = Config.load(from: missing)
    #expect(cfg.hotkey.key == "j")
    #expect(cfg.hotkey.modifiers.contains("cmd"))
}

@Test func configParsesCustomHotkey() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("cfg-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try #"{"hotkey":{"key":"space","modifiers":["control","option"]}}"#
        .write(to: tmp, atomically: true, encoding: .utf8)
    let cfg = Config.load(from: tmp)
    #expect(cfg.hotkey.key == "space")
    #expect(cfg.hotkey.modifiers == ["control", "option"])
}

@Test func configFallsBackOnGarbage() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("cfg-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try "not json at all".write(to: tmp, atomically: true, encoding: .utf8)
    let cfg = Config.load(from: tmp)
    #expect(cfg.hotkey.key == "j")   // default
}

@Test func compactionRewritesToPendingSnapshot() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("compact-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: tmp) }

    // Build a log with lots of churn: session "a" ends pending, "b" cleared,
    // plus padding to exceed a tiny threshold.
    var lines: [String] = []
    for i in 0..<200 {
        lines.append(#"{"schema":1,"ts":"t\#(i)","kind":"idle","session_id":"pad\#(i)","pane_id":"%\#(i)"}"#)
        lines.append(#"{"schema":1,"ts":"t\#(i)","kind":"clear","session_id":"pad\#(i)","pane_id":"%\#(i)"}"#)
    }
    lines.append(#"{"schema":1,"ts":"z","kind":"idle","session_id":"a","pane_id":"%900"}"#)
    try (lines.joined(separator: "\n") + "\n").write(to: tmp, atomically: true, encoding: .utf8)

    let store = EventStore(url: tmp)
    let before = store.refresh()
    #expect(before.count == 1)            // only "a" pending
    #expect(before[0].sessionId == "a")

    // Compact with a tiny threshold so it triggers.
    let didCompact = store.compactIfNeeded(threshold: 100)
    #expect(didCompact)

    // File should now contain just the one pending session.
    let contents = try String(contentsOf: tmp, encoding: .utf8)
    let remaining = contents.split(separator: "\n").count
    #expect(remaining == 1)

    // A fresh store over the compacted file yields the same pending set.
    let store2 = EventStore(url: tmp)
    let after = store2.refresh()
    #expect(after.count == 1)
    #expect(after[0].sessionId == "a")
}
