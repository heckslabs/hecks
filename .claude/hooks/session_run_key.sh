#!/usr/bin/env bash
# Sourced by the inbox watch scripts: `session_run_key <session>` prints the key of the run that
# session is, found in the AgentRun ledger or a registered HandRun, and nothing when it is none.
# Read-only sqlite3 lookups; ledgers are found under $HECKS_DEV_DIR or ~/.claude/hecks-dev.

session_run_key() {
  local dev="${HECKS_DEV_DIR:-$HOME/.claude/hecks-dev}" session key
  session="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9-')"
  [ -n "$session" ] || return 0
  lookup() { sqlite3 -readonly -cmd ".timeout 200" "$@" 2>/dev/null; }
  key="$(lookup "$dev/agent_run.db" "select json_extract(run,'\$.value') from agent_run where status='started' and json_extract(session,'\$.value')<>'' and '$session' like json_extract(session,'\$.value')||'%' limit 1")"
  [ -n "$key" ] || key="$(lookup "$dev/agents.db" "select json_extract(run,'\$.value') from hand_run where json_extract(session,'\$.value')<>'' and '$session' like json_extract(session,'\$.value')||'%' limit 1")"
  printf '%s' "$key" | tr -cd 'A-Za-z0-9._~-'
}
