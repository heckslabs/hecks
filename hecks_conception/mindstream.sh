#!/bin/bash
# Mindstream — the unconscious that never stops
# Dispatches bluebook commands on a 10s loop. Drives sleep progression
# when consciousness.state == "sleeping" — NOT a synchronous policy cascade
# (that version made sleep complete instantly and invisible to the status bar).
#
# Usage: ./mindstream.sh &

HECKS="../hecks_life/target/release/hecks-life"
DIR="$(dirname "$0")"
INFO="$DIR/information"
PIDFILE="$INFO/.mindstream.pid"

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

# Sleep stage cycle: light → rem → deep → light...
next_stage() {
  case "$1" in
    "light")    echo "rem" ;;
    "rem")      echo "deep" ;;
    "deep")     echo "light" ;;
    *)          echo "light" ;;
  esac
}

while true; do
  # Tick
  $HECKS "$DIR/aggregates" Tick.MindstreamTick 2>/dev/null

  # Read consciousness state
  consciousness_json=$($HECKS heki read "$INFO/consciousness.heki" 2>/dev/null)
  state=$(echo "$consciousness_json" | python3 -c "import json,sys; d=json.load(sys.stdin); r=next(iter(d.values()),{}); print(r.get('state',''))" 2>/dev/null)

  if [ "$state" = "sleeping" ]; then
    # Drive sleep progression — each tick advances a stage; every third tick
    # completes a full light/rem/deep cycle and increments sleep_cycle.
    current_stage=$(echo "$consciousness_json" | python3 -c "import json,sys; d=json.load(sys.stdin); r=next(iter(d.values()),{}); print(r.get('sleep_stage','') or 'light')" 2>/dev/null)
    current_cycle=$(echo "$consciousness_json" | python3 -c "import json,sys; d=json.load(sys.stdin); r=next(iter(d.values()),{}); print(r.get('sleep_cycle',0))" 2>/dev/null)
    total=$(echo "$consciousness_json" | python3 -c "import json,sys; d=json.load(sys.stdin); r=next(iter(d.values()),{}); print(r.get('sleep_total',8))" 2>/dev/null)

    new_stage=$(next_stage "$current_stage")
    # A full cycle completes on each return to "light"
    if [ "$new_stage" = "light" ]; then
      new_cycle=$((current_cycle + 1))
    else
      new_cycle=$current_cycle
    fi

    # Wake automatically when all cycles complete
    if [ "$new_cycle" -ge "$total" ]; then
      $HECKS "$DIR/aggregates" Consciousness.WakeUp 2>/dev/null
      $HECKS "$DIR/aggregates" Consciousness.BecomeAttentive 2>/dev/null
    else
      id=$(echo "$consciousness_json" | python3 -c "import json,sys; d=json.load(sys.stdin); r=next(iter(d.values()),{}); print(r.get('id',''))" 2>/dev/null)
      $HECKS "$DIR/aggregates" Consciousness.AdvanceSleep \
        consciousness="$id" stage="$new_stage" cycle="$new_cycle" 2>/dev/null
    fi

    # Status bar narrative
    $HECKS heki upsert "$INFO/consciousness.heki" \
      sleep_summary="cycle $new_cycle/$total — $new_stage" 2>/dev/null
  else
    # Awake: surface a musing for the status bar
    thought=$($HECKS heki read "$INFO/musing.heki" 2>/dev/null | python3 -c "
import json, sys, time
d = json.load(sys.stdin)
ideas = [v.get('idea','') for v in d.values() if not v.get('conceived', False)]
if ideas:
    print(ideas[int(time.time()) % len(ideas)][:80])
" 2>/dev/null)
    if [ -n "$thought" ]; then
      $HECKS heki upsert "$INFO/consciousness.heki" sleep_summary="$thought" 2>/dev/null
    fi
  fi

  sleep 10
done
