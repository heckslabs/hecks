#!/usr/bin/env bash
# Sourced by the SessionStart hook: `session_loops_text <session>` prints the loops a pinned session
# is to re-create, and nothing when the session is not one. The loops are the Watchdog bluebook's
# rows, written by the watchdog loop to `loops.json`; the session is found by its listed name. It
# leaves a stamp the watchdog reads to see that the start hook ran after a resume. Reads only.

session_loops_text() {
  local dir="${HECKS_DEV_DIR:-$HOME/.claude/hecks-dev}/watchdog" session name loops
  session="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9-')"
  [ -n "$session" ] && [ -f "$dir/loops.json" ] || return 0
  command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  name="$(claude agents --json --all 2>/dev/null | jq -r --arg s "$session" \
    '[.[] | select((.sessionId // .id // "") | startswith($s) or ($s | startswith(.)))][0].name // empty' 2>/dev/null)"
  [ -n "$name" ] || return 0
  loops="$(jq -r --arg n "$name" '.[$n] // [] | .[] | "- " + .kind + (if .schedule != "" then " [" + .schedule + "]" else "" end) + ": " + .prompt' "$dir/loops.json" 2>/dev/null)"
  [ -n "$loops" ] || return 0
  mkdir -p "$dir/armed" && : > "$dir/armed/$name"
  printf ' You are the pinned session %s: re-create your loops now (crons with CronCreate, monitors and watches with Monitor):\n%s\n' "$name" "$loops"
}
