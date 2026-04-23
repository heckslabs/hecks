#!/bin/bash
# SleepCycle — the NREM/REM alternation while sleeping.
#
# Gates on consciousness.state. When state == "sleeping", the inner
# loop cycles NREM light → NREM deep → REM at ~90-minute intervals
# (5400s between phase transitions). When awake, the daemon does a
# long 60s sleep and rechecks — it does NOT exit between sessions.
# This way the cycle_count accumulates across nights without the
# daemon needing to be restarted.
#
# SLEEP_CYCLE_TICK overrides the 5400s inner cadence so CI and smoke
# tests can exercise the phase transitions in seconds instead of
# hours. The outer (awake-polling) cadence stays at 60s regardless.
#
# Body cycles run independently of the mindstream. This daemon's
# only job is cadence while sleeping: flip the phase and let the
# aggregate record the count. No policies fire off sleep_cycle
# events today.
#
# [antibody-exempt: body-cycle shell daemon; retires when body
# cycles port to .bluebook + .hecksagon dispatched by hecks-life run
# (i3 PR-d onwards)]

HECKS="../hecks_life/target/release/hecks-life"
DIR="$(dirname "$0")"
INFO="${HECKS_INFO:-$DIR/information}"
AGG="$DIR/aggregates"
PIDFILE="$INFO/.sleep_cycle.pid"
TICK="${SLEEP_CYCLE_TICK:-5400}"

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

is_sleeping() {
  # Read consciousness.state; treat missing store / missing field
  # as awake. Any non-zero read error also falls through to awake.
  state=$($HECKS heki latest "$INFO/consciousness.heki" 2>/dev/null \
    | grep -E '"state"[[:space:]]*:' \
    | head -1 \
    | sed -E 's/.*"state"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
  [ "$state" = "sleeping" ]
}

while true; do
  if is_sleeping; then
    $HECKS "$AGG" SleepCycle.EnterNREMLight 2>/dev/null
    sleep "$TICK"
    is_sleeping || continue
    $HECKS "$AGG" SleepCycle.EnterNREMDeep 2>/dev/null
    sleep "$TICK"
    is_sleeping || continue
    $HECKS "$AGG" SleepCycle.EnterREM 2>/dev/null
    sleep "$TICK"
  else
    sleep 60
  fi
done
