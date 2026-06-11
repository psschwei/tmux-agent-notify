#!/usr/bin/env bash
# claude-tmux-notify.sh — Claude Code hook that records, for the tmux-agent-notify
# menu-bar app, when a Claude Code session needs attention.
#
# Wired (in ~/.claude/settings.json) to: Notification, Stop, UserPromptSubmit,
# SessionStart, SessionEnd. Reads the hook JSON on stdin and appends ONE enriched
# JSON line to ~/.claude-tmux-notify/events.jsonl.
#
# Key fact this relies on: tmux exports $TMUX and $TMUX_PANE into the pane shell,
# and Claude Code's hook child process inherits them — so we read the pane id
# straight from the environment. No heuristics.

set -u

# --- locate tools (hook PATH is minimal; do not assume Homebrew is on PATH) ---
# NOTE: do not name this TMUX — that env var holds the tmux *socket*, which we read below.
JQ="$(command -v jq || true)";       [ -n "$JQ" ]       || JQ=/opt/homebrew/bin/jq
TMUX_BIN="$(command -v tmux || true)"; [ -n "$TMUX_BIN" ] || TMUX_BIN=/opt/homebrew/bin/tmux

BASE_DIR="$HOME/.claude-tmux-notify"
EVENTS="$BASE_DIR/events.jsonl"
LOCK="$EVENTS.lock"
mkdir -p "$BASE_DIR"

# --- read the hook payload once ---
payload="$(cat)"

# Extract with `// empty` so a missing field becomes "" rather than the string "null".
get() { printf '%s' "$payload" | "$JQ" -r "$1 // empty" 2>/dev/null; }

event="$(get '.hook_event_name')"
session_id="$(get '.session_id')"
cwd="$(get '.cwd')"
transcript_path="$(get '.transcript_path')"
notification_type="$(get '.notification_type')"
message="$(get '.message')"
title="$(get '.title')"

# --- derive the logical kind the app reconciles on ---
case "$event" in
  Notification)
    case "$notification_type" in
      permission_prompt) kind="permission" ;;
      idle_prompt)       kind="idle" ;;
      *)                 kind="idle" ;;   # other notifications: treat as attention
    esac
    ;;
  Stop)             kind="idle" ;;
  UserPromptSubmit) kind="clear" ;;
  SessionStart)     kind="clear" ;;       # (re)start clears prior pending + rebinds pane
  SessionEnd)       kind="end" ;;
  *)                kind="idle" ;;
esac

# --- pane context from the environment (NOT from stdin) ---
pane_id="${TMUX_PANE:-}"
tmux_socket="${TMUX:-}"

tmux_session=""; window_id=""; window_index=""; client_tty=""; pane_title=""; pane_cmd=""
if [ -n "$pane_id" ]; then
  # Capture context at event time so a later-closed pane still renders. Use a literal
  # tab as the separator (tmux's display-message FORMAT does not expand \t).
  fmt=$'#{session_name}\t#{window_id}\t#{window_index}\t#{client_tty}\t#{pane_title}\t#{pane_current_command}'
  if info="$("$TMUX_BIN" display-message -p -t "$pane_id" "$fmt" 2>/dev/null)"; then
    IFS=$'\t' read -r tmux_session window_id window_index client_tty pane_title pane_cmd <<< "$info"
  fi
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- build the line with jq (safe against quotes/newlines in message/title) ---
line="$("$JQ" -c -n \
  --argjson schema 1 \
  --arg ts "$ts" \
  --arg event "$event" \
  --arg kind "$kind" \
  --arg session_id "$session_id" \
  --arg pane_id "$pane_id" \
  --arg tmux_socket "$tmux_socket" \
  --arg tmux_session "$tmux_session" \
  --arg window_id "$window_id" \
  --arg window_index "$window_index" \
  --arg client_tty "$client_tty" \
  --arg pane_title "$pane_title" \
  --arg pane_cmd "$pane_cmd" \
  --arg cwd "$cwd" \
  --arg transcript_path "$transcript_path" \
  --arg message "$message" \
  --arg title "$title" \
  '{schema:$schema, ts:$ts, event:$event, kind:$kind, session_id:$session_id,
    pane_id:$pane_id, tmux_socket:$tmux_socket, tmux_session:$tmux_session,
    window_id:$window_id, window_index:$window_index, client_tty:$client_tty,
    pane_title:$pane_title, pane_cmd:$pane_cmd, cwd:$cwd,
    transcript_path:$transcript_path, message:$message, title:$title}')"

# --- atomic append under flock (flock may be absent on macOS; degrade gracefully) ---
if command -v flock >/dev/null 2>&1; then
  ( flock 9; printf '%s\n' "$line" >> "$EVENTS" ) 9>"$LOCK"
else
  printf '%s\n' "$line" >> "$EVENTS"
fi

exit 0
