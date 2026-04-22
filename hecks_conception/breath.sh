#!/bin/bash
# Breath — the ~0.2Hz body cycle. Alternates Inhale/Exhale every 4.5s
# so a full breath takes ~9s (roughly 13 breaths/minute).
#
# Body cycles run independently of the mindstream. This daemon's only
# job is cadence: flip the phase and let the aggregate record the
# count. No policies fire off breath events today; when something
# needs to react to a breath, it'll listen for BreathInhaled /
# BreathExhaled.
#
# [antibody-exempt: body-cycle shell daemon; retires when
# mindstream/heart/breath/circadian migrate to .bluebook + .hecksagon
# dispatched by hecks-life run (planned i3 PR-d)]

HECKS="../hecks_life/target/release/hecks-life"
DIR="$(dirname "$0")"
INFO="$DIR/information"
AGG="$DIR/aggregates"
PIDFILE="$INFO/.breath.pid"

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

while true; do
  $HECKS "$AGG" Breath.Inhale 2>/dev/null
  sleep 4.5
  $HECKS "$AGG" Breath.Exhale 2>/dev/null
  sleep 4.5
done
