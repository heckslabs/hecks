#!/bin/bash
# Mindstream — the unconscious that never stops
# Replaces daemon/mindstream.rs with a shell loop + bluebook dispatch
# Usage: ./mindstream.sh &

HECKS="../hecks_life/target/release/hecks-life"
DIR="$(dirname "$0")"
PIDFILE="$DIR/information/.mindstream.pid"

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

while true; do
  $HECKS "$DIR/aggregates" Tick.MindstreamTick 2>/dev/null
  sleep 10
done
