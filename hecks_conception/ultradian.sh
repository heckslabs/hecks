#!/bin/bash
# Ultradian — the ~90-minute body cycle (BRAC). Alternates EnterPeak
# and EnterTrough every 5400s so a full peak→trough→peak loop is one
# counted cycle. cycle_count increments on EnterPeak, so the first
# peak entry at boot counts as cycle 1.
#
# The cadence is slow enough that tests would be painful; the
# ULTRADIAN_TICK env var overrides the 5400s sleep so CI and smoke
# tests can exercise the phase transitions in seconds instead of
# hours. No env var → real 90-min cadence.
#
# Body cycles run independently of the mindstream. This daemon's
# only job is cadence: flip the phase and let the aggregate record
# the count. No policies fire off ultradian events today.
#
# [antibody-exempt: body-cycle shell daemon; retires when body
# cycles port to .bluebook + .hecksagon dispatched by hecks-life run
# (i3 PR-d onwards)]

HECKS="../hecks_life/target/release/hecks-life"
DIR="$(dirname "$0")"
INFO="${HECKS_INFO:-$DIR/information}"
AGG="$DIR/aggregates"
PIDFILE="$INFO/.ultradian.pid"
TICK="${ULTRADIAN_TICK:-5400}"

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

while true; do
  $HECKS "$AGG" Ultradian.EnterPeak 2>/dev/null
  sleep "$TICK"
  $HECKS "$AGG" Ultradian.EnterTrough 2>/dev/null
  sleep "$TICK"
done
