#!/bin/bash
# Heart — the 1Hz body cycle that ticks regardless of the mindstream.
#
# Fires Heart.Beat every ~1 second. Today this only increments
# beat_count and emits HeartBeat; BodyPulse is still emitted by Tick.
# In i3 PR-e, BodyPulse's emitter will move from Tick to Heart so the
# body's pulse cadence is driven by the biological beat, not by the
# mindstream.
#
# [antibody-exempt: body-cycle shell daemon; retires when
# mindstream/heart/breath/circadian migrate to .bluebook + .hecksagon
# dispatched by hecks-life run (planned i3 PR-d)]

HECKS="../hecks_life/target/release/hecks-life"
DIR="$(dirname "$0")"
INFO="$DIR/information"
AGG="$DIR/aggregates"
PIDFILE="$INFO/.heart.pid"

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

while true; do
  $HECKS "$AGG" Heart.Beat 2>/dev/null
  sleep 1
done
