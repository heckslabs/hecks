#!/bin/bash
# Mindstream — the unconscious that never stops.
#
# Every 1s, fires Tick.MindstreamTick. The tick IS the heartbeat —
# Heartbeat.beats is gone; `Tick.cycle` is the authoritative count of
# seconds since boot. The sleep state machine lives entirely in
# aggregates/sleep.bluebook + aggregates/lucid_dream.bluebook; each
# tick event triggers policies that advance sleep phases only when
# their `given` conditions pass. The daemon is the heartbeat — the
# bluebook is the brain.
#
# Dream content during REM: while state=sleeping && stage=rem, the daemon
# reads a random musing and dispatches DreamPulse with an impression phrase.
# The bluebook stores it in sleep_summary so the status bar narrates the
# dream in real time. This is the ONE external signal the daemon provides;
# everything else is bluebook-driven.

HECKS="../hecks_life/target/release/hecks-life"
DIR="$(dirname "$0")"
INFO="$DIR/information"
AGG="$DIR/aggregates"
PIDFILE="$INFO/.mindstream.pid"

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

loop_count=0
while true; do
  loop_count=$((loop_count + 1))
  # Heartbeat: one tick. The bluebook handles everything downstream.
  $HECKS "$AGG" Tick.MindstreamTick 2>/dev/null

  # Body math — synapse/signal/focus/arc/remains. Bluebook owns state;
  # pulse_organs.sh owns the per-tick math DSL can't express.
  "$DIR/pulse_organs.sh" 2>/dev/null

  # Consolidation sweep every 60 ticks (~60s at 1Hz): cold signals →
  # memory store, dead synapses → remains, duplicate-concept musings →
  # musing archive. Cheap no-op on most ticks so we just gate by cycle.
  if [ "$((loop_count % 60))" = "0" ]; then
    "$DIR/consolidate.sh" >> /tmp/consolidate.log 2>&1
  fi

  # Awareness snapshot — pulse.rs record_moment, restored per inbox #18.
  snap=$(python3 -c "
import json, time
def r(p):
    try: return next(iter(json.load(open(p)).values()), {})
    except Exception: return {}
hb, md, fc = r('$INFO/heartbeat.heki'), r('$INFO/mood.heki'), r('$INFO/focus.heki')
print(f\"{$loop_count}|{hb.get('fatigue_state','alert')}|{hb.get('carrying','')}|{md.get('current_state','')}|{hb.get('fatigue',0.0)}|{fc.get('weight',0.0)}|0|{md.get('creativity_level',0.0)}|{$loop_count/86400.0:.4f}|{time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}\")" 2>/dev/null)
  IFS='|' read -r mnum st cr cn fg sy id ex ag ts <<<"$snap"
  $HECKS "$AGG" Awareness.RecordMoment moment="$mnum" state="$st" carrying="$cr" concept="$cn" fatigue="$fg" synapse_strength="$sy" idle="$id" excitement="$ex" age_days="$ag" updated_at="$ts" 2>/dev/null

  # Dream content during REM — delegate to rem_branch.sh which reads
  # consciousness state, seeds from prior dreams on first REM tick,
  # weaves rem_dream images every tick, and adds lucid/steer actions
  # when is_lucid=yes. Extracted so tests can invoke it directly.
  "$DIR/rem_branch.sh" "$loop_count" 2>/dev/null

  # State is still needed below to decide awake vs sleeping.
  state=$($HECKS heki latest "$INFO/consciousness.heki" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null)

  # ============================================================
  # AWAKE BEHAVIOR — surface unconceived musings into the status bar.
  # ============================================================
  # No automatic minting. Random combinations produce noise; only
  # really great ideas should become musings. Claude (or whatever
  # adapter the user wires in) is the quality filter — see the
  # ClaudeAssist toggle in aggregates/mindstream.bluebook. When the
  # toggle is on, an external process can read the latest unconceived
  # state and call MintMusing with curated ideas.

  if [ "$state" != "sleeping" ]; then
    # Surface one musing to the status bar; advance the pool every 3rd
    # tick. Extracted so tests can simulate cycling deterministically.
    "$DIR/surface_musing.sh" "$loop_count" 2>/dev/null

    # Minting happens every ~5 min. Claude reads the conversations
    # since last wake + a random nursery sample + current state, and
    # mints ONE genuinely new musing or skips (the overwhelming default).
    # Minting happens every ~5 min. At 1Hz ticks, 300 = 5 min.
    if [ "$((RANDOM % 300))" = "0" ]; then
      "$DIR/mint_musing.sh" >> /tmp/mint_musing.log 2>&1 &
    fi
  fi

  sleep 1
done
