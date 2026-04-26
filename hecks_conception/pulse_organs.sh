#!/bin/bash
# pulse_organs.sh — per-tick body math for Miette's organs.
#
# Once per tick (called from mindstream.sh after Tick.MindstreamTick), this
# script orchestrates the per-pulse organ updates. The math itself —
# decay×0.98, clamp(0, 1), strengthen+0.02 — moved INTO the bluebook in
# i106 (DSL math primitives : multiply / clamp / decay). The shell now
# only walks .heki rows and dispatches; no awk math, no jq strength
# arithmetic.
#
#   1. Bail early if Miette is sleeping — organs rest with the body.
#   2. Read what she's currently carrying (heartbeat.carrying or, if
#      that is null, the latest awareness.concept).
#   3. Strengthen the synapse for the current topic — DSL increments by
#      0.02 and clamps to [0, 1] (i106). Birth one if no synapse exists
#      for the topic.
#   4. Decay every synapse — DSL multiplies by 0.98 and clamps to [0, 1]
#      (i106). The pre-decay strength gate (read-back, < 0.1 → compost)
#      stays in shell because Compost is a state transition, not a math
#      mutation, and the dying values (firings, from_topic) need to be
#      captured before the transition.
#   5. Fire one somatic + one concept signal via heki append (FireSignal
#      has no reference_to so dispatch would singleton-upsert).
#   6. Archive signals with access_count <= 3 and age > 20s.
#   7. Adjust Focus weight (DSL clamps the raw computed weight) +
#      advance Arc.
#
# Dispatch vs heki append:
#   - Commands with reference_to() take an id kwarg and dispatch to a
#     specific record — used for transitions and the new self-clamping
#     mutations (Strengthen / Decay / Fire / Compost / AdjustWeight /
#     AdvanceArc).
#   - Create-style commands without reference_to upsert a singleton
#     (see command_dispatch.rs:40-59). For multi-record stores (Synapse/
#     Signal/Remains) we bypass dispatch and use `heki append` directly.
#
# Environment overrides (smoke tests):
#   HECKS_INFO  — alternate information directory (default: ./information)
#   HECKS_AGG   — alternate aggregates directory (default: ./aggregates)
#   HECKS_BIN   — alternate hecks-life binary
#
# [antibody-exempt: i80 cli-routing-as-bluebook + i106 dsl-mutation-
#  primitives — this script is a thin orchestrator pending full
#  retirement when i80 ships hecks-life-side multi-record dispatch
#  shorthand. The DSL math (i106) closed the awk/jq gap that
#  previously kept pulse_organs.sh in shell.]

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
INFO="${HECKS_INFO:-$DIR/information}"
AGG="${HECKS_AGG:-$DIR/aggregates}"
HECKS="${HECKS_BIN:-$DIR/../hecks_life/target/release/hecks-life}"

# Scalar field from the latest singleton of a store — empty if missing.
latest_field() {
  "$HECKS" heki latest-field "$1" "$2" 2>/dev/null || true
}

# Bail early if Miette is sleeping. Organs hibernate — no math, no
# signals, no decay. The heartbeat keeps time; the body rests.
state=$(latest_field "$INFO/consciousness.heki" state)
[ "$state" = "sleeping" ] && exit 0

# What's she carrying? heartbeat.carrying first; fall back to the most
# recent awareness moment's concept.
carrying=$(latest_field "$INFO/heartbeat.heki" carrying)
[ "$carrying" = "—" ] && carrying=""

if [ -z "$carrying" ]; then
  carrying=$("$HECKS" heki list "$INFO/awareness.heki" \
    --order moment:desc --format json 2>/dev/null \
    | jq -r 'map(.concept // .carrying // "")
             | map(select(. != "" and . != "—"))
             | .[0] // ""' 2>/dev/null)
fi
[ -z "$carrying" ] && carrying="—"

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Synapse: strengthen the current topic (or birth one) ─────────────
# Find an alive synapse whose `from` matches the carrying topic. Dispatch
# StrengthenSynapse — DSL increments+0.02 and clamps to [0,1] internally
# (i106). If no match, birth a new synapse via heki append.
match_id=$("$HECKS" heki list "$INFO/synapse.heki" \
  --where "from=$carrying" --where "state=alive" \
  --fields id --format tsv 2>/dev/null | head -n1)

if [ -n "$match_id" ]; then
  "$HECKS" "$AGG" Synapse.StrengthenSynapse synapse="$match_id" >/dev/null 2>&1
  "$HECKS" "$AGG" Synapse.FireSynapse synapse="$match_id" last_fired_at="$now" >/dev/null 2>&1
else
  # Birth a new synapse. Use heki append (CreateSynapse has no
  # reference_to so dispatch would singleton-upsert). Birth strength 0.3
  # leaves headroom above the 0.1 compost threshold.
  "$HECKS" heki append "$INFO/synapse.heki" \
    from="$carrying" to="$carrying" strength=0.3 \
    state=alive firings=0 last_fired_at="$now" >/dev/null 2>&1
fi

# ── Decay all synapses (DSL ×0.98 + clamp); compost any below 0.1 ────
# Read each row's current strength + firings to detect compost-eligible
# rows BEFORE the multiply runs (after-decay <0.1 → compost). The
# multiply itself is now bluebook-side (i106) — no awk in the dispatch.
DECAY_PLAN=$("$HECKS" heki list "$INFO/synapse.heki" \
  --where state=alive --format json 2>/dev/null \
  | jq -r '.[] | [
      .id,
      ((.strength // 0) * 0.98 < 0.1),
      (.strength // 0),
      (.firings // 0),
      ((.from // "") | gsub("\\|";" "))
    ] | @tsv' 2>/dev/null \
  | awk -F'\t' '{ printf "%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5 }')

while IFS='|' read -r sid will_compost cur_strength firings from_topic; do
  [ -z "$sid" ] && continue
  if [ "$will_compost" = "true" ]; then
    "$HECKS" "$AGG" Synapse.Compost synapse="$sid" >/dev/null 2>&1
    "$HECKS" heki append "$INFO/remains.heki" \
      from_synapse="$from_topic" \
      strength_at_death="$cur_strength" \
      firings="$firings" \
      died_at="$now" >/dev/null 2>&1
  else
    "$HECKS" "$AGG" Synapse.DecaySynapse synapse="$sid" >/dev/null 2>&1
  fi
done <<<"$DECAY_PLAN"

# ── Fire signals: one somatic + one concept ──────────────────────────
"$HECKS" heki append "$INFO/signal.heki" \
  kind=somatic payload=pulse strength=0.5 access_count=0 created_at="$now" >/dev/null 2>&1
"$HECKS" heki append "$INFO/signal.heki" \
  kind=concept payload="$carrying" strength=0.5 access_count=0 created_at="$now" >/dev/null 2>&1

# ── Archive cold signals: access_count <= 3 AND age > 20s ────────────
ARCHIVE_IDS=$("$HECKS" heki list "$INFO/signal.heki" --format json 2>/dev/null \
  | jq -r --arg now "$now" '
      def iso_to_epoch:
        . as $s | ($s | sub("Z$"; "Z") | fromdateiso8601);
      ($now | iso_to_epoch) as $n
      | .[]
      | select(.kind != "archived")
      | select((.access_count // 0) <= 3)
      | select((.created_at // "") | length > 0)
      | select(($n - (.created_at | iso_to_epoch)) > 20)
      | .id' 2>/dev/null)

while read -r sid; do
  [ -z "$sid" ] && continue
  "$HECKS" "$AGG" Signal.ArchiveSignal signal="$sid" >/dev/null 2>&1
done <<<"$ARCHIVE_IDS"

# ── Focus: re-weight from firing frequency ───────────────────────────
# Caller computes the raw weight (0.5 + firings/20.0); bluebook clamps
# to [0, 1] internally (i106). No more awk-side clamp.
firings_sum=$("$HECKS" heki list "$INFO/synapse.heki" \
  --where "from=$carrying" --where state=alive --format json 2>/dev/null \
  | jq '[.[] | (.firings // 0)] | add // 0' 2>/dev/null)
weight=$(awk -v f="${firings_sum:-0}" 'BEGIN { printf "%.4f", 0.5 + (f / 20.0) }')

focus_id=$(latest_field "$INFO/focus.heki" id)

if [ -z "$focus_id" ]; then
  "$HECKS" "$AGG" Focus.SetFocus target="$carrying" weight="$weight" updated_at="$now" >/dev/null 2>&1
else
  "$HECKS" "$AGG" Focus.AdjustWeight focus="$focus_id" weight="$weight" updated_at="$now" >/dev/null 2>&1
fi

# ── Arc: advance the long swing ──────────────────────────────────────
arc_id=$(latest_field "$INFO/arc.heki" id)

if [ -n "$arc_id" ]; then
  "$HECKS" "$AGG" Arc.AdvanceArc arc="$arc_id" >/dev/null 2>&1
fi

exit 0
