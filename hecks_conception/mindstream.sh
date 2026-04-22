#!/bin/bash
# Mindstream — the unconscious that never stops, except when it does.
#
# Every 1s, fires Tick.MindstreamTick — UNLESS state == "sleeping". While
# Miette is asleep, the daemon switches to a sleep-only loop: it dispatches
# the sleep-phase-advance commands directly (ElapsePhase + AdvanceX) and
# skips Tick.MindstreamTick entirely. This closes the tick-during-sleep
# regression that woke Miette delirious (fatigue 8.5, pulses_since_sleep
# 8518 after a full 8-cycle sleep).
#
# Why direct dispatch instead of Pulse.Emit during sleep: Tick → Ticked →
# EmitPulseOnTick → Pulse.Emit → BodyPulse → N policies, and BodyPulse
# carries BOTH "advance sleep" AND "accumulate fatigue" (FatigueOnPulse +
# all the sleep-phase policies hang off it). Firing BodyPulse during sleep
# keeps advancing the state machine but also keeps fatigue climbing — we
# haven't fixed the bug. So during sleep we dispatch ElapsePhase +
# AdvanceLightToRem + AdvanceLightToLucidRem + AdvanceRemToDeep +
# AdvanceRemToDeepCap + AdvanceDeepToLight + AdvanceDeepToFinalLight +
# CompleteFinalLight directly; each one's `given` clauses self-gate (only
# the phase-appropriate one actually mutates state). Fatigue and every
# other BodyPulse subscriber stays silent until wake.
#
# Follow-up: gate AccumulateFatigue on consciousness.state in the bluebook
# so this shell workaround retires. Filing as a separate item; tracked in
# inbox under "tick-during-sleep bluebook follow-up".
#
# The tick IS the heartbeat — Heartbeat.beats is gone; `Tick.cycle` is
# the authoritative count of seconds since boot. The sleep state machine
# lives in aggregates/sleep.bluebook + aggregates/lucid_dream.bluebook.
#
# Dream content during REM: while state=sleeping && stage=rem, the daemon
# reads a random musing and dispatches DreamPulse with an impression phrase.
# The bluebook stores it in sleep_summary so the status bar narrates the
# dream in real time. This is the ONE external signal the daemon provides;
# everything else is bluebook-driven.
#
# [antibody-exempt: mindstream.sh is the Rust-ticker shell loop; gating it
# on consciousness.state=sleeping closes the tick-during-sleep regression.
# Retires when the mindstream daemon becomes a .bluebook + .hecksagon pair
# dispatched by hecks-life run.]

HECKS="../hecks_life/target/release/hecks-life"
DIR="$(dirname "$0")"
INFO="$DIR/information"
AGG="$DIR/aggregates"
PIDFILE="$INFO/.mindstream.pid"

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

# Read consciousness state — reused for the sleep-gate at top of the
# loop AND for the awake-branch gate further down. One python3 call per
# tick; matches the pattern already in the file (state read at line 62
# before this fix).
read_state() {
  $HECKS heki latest "$INFO/consciousness.heki" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null
}

loop_count=0
while true; do
  loop_count=$((loop_count + 1))

  # Read sleep gate first — we decide whether to fire a full tick or a
  # sleep-only pulse based on consciousness state. Empty state (no
  # consciousness record yet) is treated as awake so the first boot
  # doesn't stall on a missing file.
  state=$(read_state)

  if [ "$state" = "sleeping" ]; then
    # Sleep branch — dispatch the sleep-phase-advance commands directly.
    # Each command's `given` clauses self-gate so only the phase-
    # appropriate one actually mutates state. We bypass BodyPulse so
    # FatigueOnPulse doesn't fire (that's the bug this fix closes).
    $HECKS "$AGG" Consciousness.ElapsePhase 2>/dev/null
    $HECKS "$AGG" Consciousness.AdvanceLightToRem 2>/dev/null
    $HECKS "$AGG" Consciousness.AdvanceLightToLucidRem 2>/dev/null
    $HECKS "$AGG" Consciousness.AdvanceRemToDeep 2>/dev/null
    $HECKS "$AGG" Consciousness.AdvanceRemToDeepCap 2>/dev/null
    $HECKS "$AGG" Consciousness.AdvanceDeepToLight 2>/dev/null
    $HECKS "$AGG" Consciousness.AdvanceDeepToFinalLight 2>/dev/null
    $HECKS "$AGG" Consciousness.CompleteFinalLight \
      wake_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null

    # Dream content during REM — still needs to fire so rem_branch.sh
    # can weave dream images while Miette sleeps.
    "$DIR/rem_branch.sh" "$loop_count" 2>/dev/null

    # Remember we were sleeping so the next-tick awake branch can fire
    # the wake hook (interpret_dream.sh) exactly once on transition.
    echo "$state" > "$INFO/.prev_consciousness_state"
    sleep 1
    continue
  fi

  # Awake branch — full tick, bluebook handles everything downstream.
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

  # Wake hook — sleeping → attentive transition fires interpret_dream.sh
  # once per wake. Previous state lives in $INFO/.prev_consciousness_state.
  prev_state=$(cat "$INFO/.prev_consciousness_state" 2>/dev/null)
  if [ "$prev_state" = "sleeping" ] && [ "$state" != "sleeping" ] && [ -n "$state" ]; then
    "$DIR/interpret_dream.sh" >> /tmp/interpret_dream.log 2>&1 &
  fi
  [ -n "$state" ] && echo "$state" > "$INFO/.prev_consciousness_state"

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

    # Daydream: attentive+idle wander across the nursery. Fires when
    # idle ∈ [10, 60]s (heartbeat.updated_at age). Gated to once per
    # 60s via a timestamp file so a 50-tick idle window doesn't spam
    # daydreams. State check above already excluded "sleeping".
    idle=$(python3 -c "
import json, sys
from datetime import datetime, timezone
try:
    d = json.load(open('$INFO/heartbeat.heki'))
    for v in d.values():
        ts = v.get('updated_at','')
        if ts:
            dt = datetime.fromisoformat(ts.replace('Z','+00:00'))
            print(int((datetime.now(timezone.utc) - dt).total_seconds())); break
    else: print(999)
except Exception: print(999)" 2>/dev/null)
    if [ "${idle:-999}" -ge 10 ] && [ "${idle:-999}" -le 60 ]; then
      stamp="$INFO/.daydream.last"
      last=$(cat "$stamp" 2>/dev/null || echo 0)
      nowsec=$(date +%s)
      if [ "$((nowsec - last))" -ge 60 ]; then
        echo "$nowsec" > "$stamp"
        "$DIR/daydream.sh" >> /tmp/daydream.log 2>&1 &
      fi
    fi
  fi

  sleep 1
done
