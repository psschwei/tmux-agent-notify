# tmux-agent-notify

A macOS menu-bar app that tells you which **Claude Code** sessions running in
**tmux** panes need your attention — and lets you jump to the right pane with a
global hotkey and a single home-row keypress.

Claude Code hooks fire when a session needs input (a permission prompt) or
finishes a turn (idle). A hook script stamps the event — including the exact
tmux pane — into a log file. The menu-bar app watches that log and drives the
navigation.

```
Claude Code hook ──▶ ~/.claude-tmux-notify/events.jsonl ──▶ menu-bar app ──▶ tmux jump
   (per session)         (append-only JSONL)                  (FSEvents)      (select-pane)
```

## How it works

- **Exact pane correlation.** tmux exports `$TMUX_PANE` into the pane shell, and
  Claude Code's hook process inherits it — so the hook records the precise pane
  id (`%62`). No guessing.
- **Only live sessions show up.** Before listing a session, the app checks that a
  real `claude` process is still running under that pane (via the process tree).
  Crashed sessions or panes reused as a plain shell are filtered out. One entry
  per pane — a lingering old session can't double up with the current one.
- **Permission-free hotkey.** The global hotkey uses Carbon `RegisterEventHotKey`,
  which needs no Accessibility grant.

## Requirements

- macOS 13+
- tmux, `jq` (Homebrew is fine; the hook resolves their paths defensively)
- Swift 6.1 toolchain (Command Line Tools — **no full Xcode required**)

## Install

```sh
# 1. Build and install the menu-bar app into ~/Applications
make install

# 2. Install the hook script, then merge the hooks into your Claude settings
make install-hooks
#    follow the printed jq command, e.g.:
jq -s '.[0] * .[1]' ~/.claude/settings.json packaging/settings.snippet.json \
  > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json

# 3. (optional) Start at login
make install-agent
```

The hooks wired are: `Notification`, `Stop`, `UserPromptSubmit`, `SessionStart`,
`SessionEnd`. They take effect for **new** Claude Code sessions.

## Use

- The menu-bar bell shows a count of sessions needing attention (red when a
  permission prompt is blocking). Click it for a dropdown; click a row to jump.
- **Global hotkey (default ⌥⌘J):** pops an overlay listing pending sessions, each
  bound to a home-row key (`a s d f …`). Press the key to jump; `Esc` to cancel.
- **Notification banners:** a native macOS banner pops when a session newly needs
  attention (and again if an idle session escalates to a permission prompt).
  Click the banner to jump straight to that pane. macOS asks for notification
  permission the first time the app runs.

## Configure the hotkey

Create `~/.claude-tmux-notify/config.json`:

```json
{ "hotkey": { "key": "j", "modifiers": ["cmd", "option"] } }
```

- `key`: a letter/digit, or `space` / `return`.
- `modifiers`: any of `cmd`, `option` (`alt`), `control` (`ctrl`), `shift`
  (at least one required).

Restart the app to apply (`make install-agent` restarts it; otherwise relaunch).

## Configure notifications

By default a banner fires for both permission prompts and idle turns. Opt out of
either kind in `~/.claude-tmux-notify/config.json`:

```json
{ "notifications": { "permission": true, "idle": false } }
```

- `permission`: banner when a session blocks on a permission prompt (audible).
- `idle`: banner when a session finishes a turn / goes idle (silent).

A missing key defaults to `true`. Restart the app to apply.

## CLI (debugging)

```sh
.build/debug/notifyctl              # list pending sessions (live only)
.build/debug/notifyctl --all        # include dead/stale entries
.build/debug/notifyctl jump <id>    # jump to a session by id prefix
```

## Terminal raising

Jumping focuses the tmux pane (always exact) and raises the host terminal app
(Tier 1: `NSWorkspace` activation, no permission). Raising the *exact* window/tab
when you have several terminal windows would need an Automation permission grant
(Tier 2) — not yet enabled.

## Uninstall

```sh
make uninstall-agent                # stop login item
rm -rf ~/Applications/TmuxAgentNotify.app
rm -rf ~/.claude-tmux-notify
# remove the "hooks" block from ~/.claude/settings.json
```

## Layout

- `hooks/claude-tmux-notify.sh` — the Claude Code hook
- `Sources/NotifyCore/` — event model, log reconciliation/tailing, tmux bridge,
  process-tree liveness, config (shared by the app and CLI)
- `Sources/notifyd/` — the menu-bar app (status item, hotkey, overlay)
- `Sources/notifyctl/` — the debugging CLI
- `packaging/` — Info.plist, LaunchAgent, settings snippet
```
