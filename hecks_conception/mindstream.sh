#!/bin/bash
# Mindstream — the unconscious that never stops
# Dispatches bluebook commands on a 10s loop
# Usage: ./mindstream.sh &

HECKS="../hecks_life/target/release/hecks-life"
DIR="$(dirname "$0")"
INFO="$DIR/information"
PIDFILE="$INFO/.mindstream.pid"

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

while true; do
  # Tick
  $HECKS "$DIR/aggregates" Tick.MindstreamTick 2>/dev/null

  # Pick a musing to display — cycle through unconceived + nursery pairs
  thought=$($HECKS heki read "$INFO/musing.heki" 2>/dev/null | python3 -c "
import json, sys, time
d = json.load(sys.stdin)
ideas = [v.get('idea','') for v in d.values() if not v.get('conceived', False)]
if ideas:
    print(ideas[int(time.time()) % len(ideas)][:80])
" 2>/dev/null)

  # Write to consciousness for the statusline to read
  if [ -n "$thought" ]; then
    $HECKS heki upsert "$INFO/consciousness.heki" sleep_summary="$thought" 2>/dev/null
  fi

  sleep 10
done
