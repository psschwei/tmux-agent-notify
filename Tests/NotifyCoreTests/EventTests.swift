import Foundation
import Testing
@testable import NotifyCore

@Test func decodesEnrichedLine() throws {
    let line = """
    {"ts":"2026-06-11T00:00:00Z","schema":1,"event":"Notification","kind":"permission",\
    "session_id":"abc","pane_id":"%62","tmux_socket":"/tmp/sock,1,0","tmux_session":"0",\
    "window_id":"@20","window_index":"1","window_name":"editor","client_tty":"/dev/ttys001",\
    "pane_title":"t","pane_cmd":"node","cwd":"/x","transcript_path":"/y","message":"need perm","title":"P",\
    "git_branch":"main","git_dirty":"1"}
    """
    let e = try JSONDecoder().decode(Event.self, from: Data(line.utf8))
    #expect(e.kind == .permission)
    #expect(e.sessionId == "abc")
    #expect(e.paneId == "%62")
    #expect(e.hasPane)
    #expect(e.windowName == "editor")
    #expect(e.gitBranch == "main")
    #expect(e.gitDirty == "1")
}

@Test func decodesMinimalLineWithoutTmux() throws {
    let line = #"{"ts":"t","schema":1,"kind":"idle","session_id":"abc","pane_id":""}"#
    let e = try JSONDecoder().decode(Event.self, from: Data(line.utf8))
    #expect(e.kind == .idle)
    #expect(!e.hasPane)
    // Git fields absent on old lines → nil (forward-compat).
    #expect(e.gitBranch == nil)
    #expect(e.gitDirty == nil)
}
