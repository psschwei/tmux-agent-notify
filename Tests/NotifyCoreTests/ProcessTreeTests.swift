import Testing
@testable import NotifyCore

// Synthetic `ps -axo pid=,ppid=,comm=` output:
//   100 = login shell, 200 = tmux server
//   300 = pane shell (zsh) under tmux, 400 = claude under that shell
//   500 = a different pane shell (zsh) with NO claude child
private let sample = """
1 0 launchd
100 1 login
200 1 tmux
300 200 zsh
400 300 claude
500 200 zsh
600 500 node
"""

@Test func detectsClaudeUnderPaneShell() {
    let t = ProcessTree(psOutput: sample)!
    #expect(t.hasDescendant(named: "claude", under: 300))   // pane with claude
}

@Test func noClaudeUnderBareShell() {
    let t = ProcessTree(psOutput: sample)!
    #expect(!t.hasDescendant(named: "claude", under: 500))   // pane with only node
}

@Test func matchesCommLeafForPathStyleComm() {
    let t = ProcessTree(psOutput: "300 200 zsh\n400 300 /usr/local/bin/claude")!
    #expect(t.hasDescendant(named: "claude", under: 300))
}

@Test func deepDescendantIsFound() {
    let t = ProcessTree(psOutput: "300 200 zsh\n400 300 sh\n410 400 claude")!
    #expect(t.hasDescendant(named: "claude", under: 300))
}

@Test func unrelatedAncestorNotMatched() {
    let t = ProcessTree(psOutput: sample)!
    #expect(!t.hasDescendant(named: "claude", under: 999))   // nonexistent pid
}
