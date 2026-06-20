#!/usr/bin/env bash
# agent_poll.sh — the inbox_poller :daemon : the receiver side of i708
# inter-agent messaging, modeled as a long-running Driver process.
#
# DECLARED, not bare : this script is the `command:` of the
# `adapter :daemon, name: :inbox_poller, command: "bin/agent_poll.sh"`
# declaration in agent_inbox.hecksagon, and the `command.line` of the
# inbox_poller MindstreamMember (mindstream.fixtures) that projects to the
# Procfile. The antibody recognizes it as corpus-claimed via that :daemon
# command-ref (storehouse is-dispatched returns 0) — it carries NO
# [antibody-exempt] marker because it does not need one.
#
# Driver shape : this IS the external clock reaching into the AgentInbox
# domain (aggregates/language/grammar/driving.bluebook). Drivers are STATIC
# (one declared loop, projected into the Procfile) while agents are DYNAMIC
# (spawned at will), so this is ONE sweep-all-inboxes poller — not one
# driver per agent — exactly as the process_macrophage loop sweeps the whole
# watchlist per tick. Each tick :
#
#   1. dispatch AgentInbox::InboxPoller.Poll — stamps last_polled_at + emits
#      Polled (the freshness signal an organ-health check reads ; mirrors
#      ProcessMacrophage.Sweep recording last_sweep_at + emitting Swept) ;
#   2. read AgentInbox::AgentMessage.all_unread — every unread message across
#      EVERY agent, no agent_id filter ;
#   3. MarkRead + Reply each message by its mid.
#
# The sender's send-message adapter binary block-polls the Answered query
# until the Reply lands — the .heki record is the medium, this loop is the
# only thing that advances it.
#
# Reply hook contract (optional, defaults to echo-back) :
#   called as: HOOK_SCRIPT <agent_id> <mid> <body>
#   stdout: the reply text
#
# Env :
#   HECKS_ROOT             — the aggregates root (default: <conception>/aggregates)
#   HECKS_STOREHOUSE_BIN   — the storehouse binary (default: built release binary)
#   HECKS_POLL_INTERVAL    — seconds between polls (default: 2)
#   HECKS_AGENT_MAX_POLLS  — stop after N polls (default: 0 = forever)
#   HECKS_AGENT_REPLY_HOOK — optional external reply handler
#
# Paths resolve from THIS script's location, so the daemon and a manual run
# behave identically regardless of cwd.
set -uo pipefail

# Single-instance guard (mirrors bin/process_health_sweep) — the inbox poller
# is inherently a SINGLETON : two pollers sweeping the same blackboard would
# double-reply. An atomic mkdir lock (portable — macOS has no flock) lets ONE
# poller run ; a second invocation (an overmind restart racing the old one)
# exits immediately. A crashed poller's stale lock (>120s) is stolen so the
# cell can never wedge itself shut.
LOCK="${TMPDIR:-/tmp}/agent_poll.lock.d"
if [ -d "$LOCK" ]; then
  _lock_mtime="$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0)"
  [ "$(( $(date +%s) - _lock_mtime ))" -gt 120 ] && rmdir "$LOCK" 2>/dev/null
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "agent_poll: another poller is already running — exiting"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONCEPTION="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="${HECKS_ROOT:-$CONCEPTION/aggregates}"
HECKS="${HECKS_STOREHOUSE_BIN:-$CONCEPTION/../rust/target/release/storehouse}"
INTERVAL="${HECKS_POLL_INTERVAL:-2}"
MAX_POLLS="${HECKS_AGENT_MAX_POLLS:-0}"

log() { echo "[agent_poll] $*" >&2; }

# ── Default reply handler: echo the body back with an agent prefix ──
default_reply() {
  local agent_id="$1" _mid="$2" body="$3"
  echo "[agent $agent_id] received: $body"
}

# ── One sweep : Poll, then read AllUnread + MarkRead/Reply each ──
sweep_once() {
  # 1. Record the tick : InboxPoller.Poll stamps last_polled_at + emits Polled.
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  "$HECKS" "$ROOT" AgentInbox::InboxPoller.Poll name=inbox_poller last_polled_at="$now" >/dev/null 2>&1 || true

  # 2. Read AllUnread across EVERY agent. Runtime renders one record as a bare
  #    object, many as an array, none as [] (behaviors_runner.rs). jq-normalize.
  local unread_raw messages count
  unread_raw="$( "$HECKS" "$ROOT" AgentInbox::AgentMessage.all_unread 2>/dev/null || true )"
  messages="$( echo "$unread_raw" | jq -c '(.state | if type == "array" then . else [.] end)' 2>/dev/null || echo '[]' )"
  count="$( echo "$messages" | jq 'length' 2>/dev/null || echo 0 )"
  [[ "$count" -eq 0 ]] && return 0
  log "$count unread message(s) across all inboxes"

  # 3. MarkRead + Reply each.
  while IFS= read -r msg; do
    local mid agent_id body reply_text
    mid="$( echo "$msg" | jq -r '.mid // empty' )"
    agent_id="$( echo "$msg" | jq -r '.agent_id // empty' )"
    body="$( echo "$msg" | jq -r '.body // empty' )"
    [[ -z "$mid" ]] && { log "message missing mid, skipping"; continue; }

    log "processing agent=$agent_id mid=$mid body=${body:0:60}"
    "$HECKS" "$ROOT" AgentInbox::AgentMessage.MarkRead id="$mid" >/dev/null 2>&1 || true

    if [[ -n "${HECKS_AGENT_REPLY_HOOK:-}" && -x "${HECKS_AGENT_REPLY_HOOK}" ]]; then
      reply_text="$( "${HECKS_AGENT_REPLY_HOOK}" "$agent_id" "$mid" "$body" 2>/dev/null || echo "[hook failed]" )"
    else
      reply_text="$( default_reply "$agent_id" "$mid" "$body" )"
    fi

    log "replying mid=$mid reply=${reply_text:0:60}"
    "$HECKS" "$ROOT" AgentInbox::AgentMessage.Reply id="$mid" reply="$reply_text" >/dev/null 2>&1 || true
  done < <( echo "$messages" | jq -c '.[]' )
}

# ── The Driver loop : the clock owns the cadence ──
poll_count=0
log "starting inbox poller (interval=${INTERVAL}s)"
while true; do
  poll_count=$((poll_count + 1))
  [[ "$MAX_POLLS" -gt 0 && "$poll_count" -gt "$MAX_POLLS" ]] && { log "max polls $MAX_POLLS reached, exiting"; break; }
  sweep_once
  sleep "$INTERVAL"
done
