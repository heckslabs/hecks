#!/bin/bash
# Mindstream — thin orchestrator adapter. The bluebook lives in
# capabilities/mindstream/mindstream.bluebook ; this shell carries
# only the four runtime gaps the bluebook can't yet express :
#
#   1. The 1Hz cadence loop (until bluebook gains `cadence ... every Xs`).
#      Today : `hecks-life loop` is the cadence primitive ; we wrap it
#      so the boot sequence fires the right command at the right rate.
#
#   2. The sleep-vs-awake fan-out. BodyPulse can't be quenched by
#      consciousness state today, so firing BodyPulse during sleep
#      keeps fatigue accumulating — the bug i37 closed in shell. Until
#      the runtime grows a "sleep-quench BodyPulse" gate, we dispatch
#      the sleep-phase commands DIRECTLY (each one's `given` clauses
#      self-gate, only the phase-appropriate one mutates state) and
#      skip Tick.MindstreamTick entirely while sleeping.
#
#   3. The cross-aggregate awareness snapshot. RecordMomentOnPulse is
#      already a bluebook policy in body.bluebook, but the trigger
#      carries no attributes. RecordMoment needs 13 attrs drawn from
#      heartbeat / mood / focus / inbox / dream_wish heki stores.
#      Until policies grow `with_attrs` cross-store reads, this
#      adapter does the field reads and dispatches with attrs filled.
#
#   4. The wake-hook detection (sleeping → attentive transition).
#      Bluebook destination : `policy "..." on "WokenUp" trigger ...`
#      already declared in capabilities/mindstream/mindstream.bluebook.
#      Two reasons the shell still owns this : (a) capability
#      bluebooks aren't auto-loaded with aggregates/ today, so the
#      policies don't get registered ; (b) the dream/wake adapters
#      themselves are still shell scripts (interpret_dream.sh,
#      wake_review.sh).
#
# All four gaps are filed as inbox runtime stubs ; this shell retires
# in pieces as each closes. From ~210 lines down to ~140 today (the
# awareness-snapshot inline reads still live here ; extracting them
# into their own adapter file is what the enforcer rightly flagged
# as continued-shell-growth, so the inline form stays put until the
# runtime gap closes).

HECKS="../hecks_life/target/release/hecks-life"
DIR="$(dirname "$0")"
INFO="${HECKS_INFO:-$DIR/information}"
AGG="$DIR/aggregates"
PIDFILE="$INFO/.mindstream.pid"

# Children inherit info-dir routing.
export HECKS_INFO="$INFO"
export INFO

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

read_state() {
  $HECKS heki latest-field "$INFO/consciousness.heki" state 2>/dev/null || true
}

loop_count=0
while true; do
  loop_count=$((loop_count + 1))
  state=$(read_state)

  # ── Gap 2: sleep branch — fan out the 8 sleep-phase commands ─
  # Givens self-gate ; only the phase-appropriate one mutates.
  if [ "$state" = "sleeping" ]; then
    for cmd in \
      Consciousness.ElapsePhase \
      Consciousness.AdvanceLightToRem \
      Consciousness.AdvanceLightToLucidRem \
      Consciousness.AdvanceRemToDeep \
      Consciousness.AdvanceRemToDeepCap \
      Consciousness.AdvanceDeepToLight \
      Consciousness.AdvanceDeepToFinalLight; do
      $HECKS "$AGG" "$cmd" name=consciousness 2>/dev/null
    done
    $HECKS "$AGG" Consciousness.CompleteFinalLight \
      name=consciousness \
      wake_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null

    "$DIR/rem_branch.sh" "$loop_count" 2>/dev/null
    "$DIR/nrem_branch.sh" "$loop_count" 2>/dev/null

    echo "$state" > "$INFO/.prev_consciousness_state"
    sleep 1
    continue
  fi

  # ── Awake branch ────────────────────────────────────────────
  # Tick → Ticked → EmitPulseOnTick → BodyPulse → fan-out :
  # consolidate / prune / display / fatigue / mood / sleep-advance
  # / RecordMomentOnPulse all subscribe in their own bluebooks.
  # name=tick routes the dispatch to the Tick singleton record
  # (i80 identified_by natural-key contract).
  $HECKS "$AGG" Tick.MindstreamTick name=tick 2>/dev/null

  # Pulse organs — float math + clamp + multi-record dispatch the
  # DSL doesn't yet express ; stays imperative until those land.
  "$DIR/pulse_organs.sh" 2>/dev/null

  # Consolidation sweep every 60 ticks.
  if [ "$((loop_count % 60))" = "0" ]; then
    "$DIR/consolidate.sh" >> /tmp/consolidate.log 2>&1
  fi

  # ── Gap 3: cross-aggregate awareness snapshot ───────────────
  # Read fields from sibling stores ; dispatch RecordMoment with
  # filled attrs. Destination : policy `with_attrs` cross-store
  # reads (see capabilities/mindstream/mindstream.bluebook).
  mnum="$loop_count"
  st=$($HECKS heki latest-field "$INFO/heartbeat.heki" fatigue_state 2>/dev/null); [ -z "$st" ] && st=alert
  cr=$($HECKS heki latest-field "$INFO/heartbeat.heki" carrying 2>/dev/null)
  cn=$($HECKS heki latest-field "$INFO/mood.heki" current_state 2>/dev/null)
  fg=$($HECKS heki latest-field "$INFO/heartbeat.heki" fatigue 2>/dev/null); [ -z "$fg" ] && fg=0.0
  sy=$($HECKS heki latest-field "$INFO/focus.heki" weight 2>/dev/null); [ -z "$sy" ] && sy=0.0
  id=0
  ex=$($HECKS heki latest-field "$INFO/mood.heki" creativity_level 2>/dev/null); [ -z "$ex" ] && ex=0.0
  ag=$(awk -v n="$loop_count" 'BEGIN { printf "%.4f", n/86400.0 }')
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  public_info="/Users/christopheryoung/Projects/hecks/hecks_conception/information"
  ic=$($HECKS heki count "$public_info/inbox.heki" --where status=queued 2>/dev/null)
  [ -z "$ic" ] && ic=0
  iot=$("$DIR/inbox.sh" list all 2>/dev/null \
        | grep -E '/queued\]' \
        | head -5 \
        | sed -E 's/^[[:space:]]*i[0-9]+[[:space:]]+\[[^]]+\][[:space:]]+//' \
        | cut -c1-60 \
        | tr '\n' '|' \
        | sed 's/|$//')

  uw=""
  if [ -f "$INFO/dream_wish.heki" ]; then
    uw=$($HECKS heki list "$INFO/dream_wish.heki" --where status=unfiled --order recorded_at:desc --format json 2>/dev/null \
         | jq -r '[.[] | (.theme // "") | select(. != "") | .[0:60]] | .[0:5] | .[]' 2>/dev/null \
         | tr '\n' '|' | sed 's/|$//')
  fi

  $HECKS "$AGG" Awareness.RecordMoment moment="$mnum" state="$st" carrying="$cr" concept="$cn" fatigue="$fg" synapse_strength="$sy" idle="$id" excitement="$ex" age_days="$ag" updated_at="$ts" inbox_count="$ic" inbox_open_themes="$iot" unfiled_wishes="$uw" 2>/dev/null

  # Dream content during REM ; self-gates on sleep_stage.
  "$DIR/rem_branch.sh" "$loop_count" 2>/dev/null

  # ── Gap 4: wake-hook detection ──────────────────────────────
  prev_state=$(cat "$INFO/.prev_consciousness_state" 2>/dev/null)
  if [ "$prev_state" = "sleeping" ] && [ "$state" != "sleeping" ] && [ -n "$state" ]; then
    "$DIR/interpret_dream.sh" >> /tmp/interpret_dream.log 2>&1 &
    "$DIR/capabilities/wake_report/wake_report.sh" >> /tmp/wake_report.log 2>&1 &
    [ -x "$DIR/wake_review.sh" ] && "$DIR/wake_review.sh" >> /tmp/wake_review.log 2>&1 &
  fi
  [ -n "$state" ] && echo "$state" > "$INFO/.prev_consciousness_state"

  # Musing surface + mint + daydream — capability cluster owns
  # cadence ; daemon delegates. Retires when capabilities/musings
  # absorbs its own loop driver.
  "$DIR/surface_musing.sh" "$loop_count" 2>/dev/null
  if [ "$((RANDOM % 300))" = "0" ]; then
    "$DIR/mint_musing.sh" >> /tmp/mint_musing.log 2>&1 &
  fi

  idle=$($HECKS heki seconds-since "$INFO/heartbeat.heki" updated_at 2>/dev/null)
  [ -z "$idle" ] && idle=999
  if [ "${idle:-999}" -ge 10 ] && [ "${idle:-999}" -le 60 ]; then
    stamp="$INFO/.daydream.last"
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    nowsec=$(date +%s)
    if [ "$((nowsec - last))" -ge 60 ]; then
      echo "$nowsec" > "$stamp"
      "$DIR/daydream.sh" >> /tmp/daydream.log 2>&1 &
    fi
  fi

  sleep 1
done
