#!/bin/bash
# pulse_organs.sh — per-tick body math for Miette's organs.
#
# This is the shell side of organs.bluebook — the bluebook owns the
# state shape (Synapse / Signal / Focus / Arc / Remains) and the events;
# this script is the math the DSL can't express. Once per tick, called
# from mindstream.sh after Tick.MindstreamTick:
#
#   1. Bail early if Miette is sleeping — organs rest with the body.
#   2. Read what she's currently carrying (heartbeat.carrying or, if
#      that is null, the latest awareness.concept).
#   3. Strengthen the synapse for the current topic — +0.02 per pulse,
#      clamped at 1.0. Birth one if no synapse exists for the topic.
#   4. Decay every synapse by ×0.98 — DSL doesn't multiply; we compute
#      the new strength here and dispatch Synapse.DecaySynapse.
#   5. Fire one somatic + one concept signal via heki append (FireSignal
#      has no reference_to so dispatch would singleton-upsert).
#   6. If a synapse fell below 0.1 → Synapse.Compost. The Composted
#      event would trigger RecordRemainsOnCompost, but policy triggers
#      carry no attrs, so we also write the remains record directly.
#   7. Archive signals with access_count <= 3 and age > 20s.
#   8. Adjust Focus weight + advance Arc.
#
# Dispatch vs heki append:
#   - Commands with reference_to() take an id kwarg and dispatch to a
#     specific record — used for transitions (Strengthen/Decay/Fire/
#     Compost/AdjustWeight/AdvanceArc).
#   - Create-style commands without reference_to upsert a singleton
#     (see command_dispatch.rs:40-59). For multi-record stores (Synapse/
#     Signal/Remains) we bypass dispatch and use `heki append` directly
#     — the pattern the rest of hecks_conception uses for multi-record
#     aggregates (see Conversation in mindstream.sh).
#
# Environment overrides (smoke tests):
#   HECKS_INFO  — alternate information directory (default: ./information)
#   HECKS_AGG   — alternate aggregates directory (default: ./aggregates)
#   HECKS_BIN   — alternate hecks-life binary
#
# DSL findings (interpreter.rs Op::Increment, line 48-60):
#   Float increment IS supported — when val.fract() != 0.0 the runtime
#   routes through state.increment_float. Integer increments go through
#   state.increment. So `then_set :strength, increment: 0.02` works
#   directly. Multiplication / clamping are NOT runtime ops — DecaySynapse
#   therefore takes :strength as a command attr and pulse_organs.sh
#   computes ×0.98 + clamp in shell before dispatching.
#
# [antibody-exempt: i37 Phase B sweep — replaces inline python3 -c with
#  native hecks-life heki subcommands per PR #272; retires when shell
#  wrapper ports to .bluebook shebang form (tracked in
#  terminal_capability_wiring plan).]

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
# recent awareness moment's concept. Default to "—" if unknown so the
# synapse path still exercises.
carrying=$(latest_field "$INFO/heartbeat.heki" carrying)
[ "$carrying" = "—" ] && carrying=""

if [ -z "$carrying" ]; then
  # Scan awareness records ordered by `moment` DESC; pick the first with
  # a non-empty concept (or carrying) that isn't the "—" placeholder.
  # jq filters the recs list — heki list returns created_at ASC by
  # default, so we reverse for newest-first.
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
# StrengthenSynapse (+0.02 via the DSL increment op). Then read back;
# if strength overshot 1.0, clamp via DecaySynapse with strength=1.0.
# If no match, birth a new synapse via heki append.
match_id=$("$HECKS" heki list "$INFO/synapse.heki" \
  --where "from=$carrying" --where "state=alive" \
  --fields id --format tsv 2>/dev/null | head -n1)

if [ -n "$match_id" ]; then
  "$HECKS" "$AGG" Synapse.StrengthenSynapse synapse="$match_id" >/dev/null 2>&1

  # Read back and clamp at 1.0 if the increment overshot.
  cur=$("$HECKS" heki get "$INFO/synapse.heki" "$match_id" strength 2>/dev/null)
  # awk beats bc/python for float compare — always available.
  overshot=$(awk -v v="$cur" 'BEGIN { print (v+0 > 1.0) ? 1 : 0 }')
  if [ "$overshot" = "1" ]; then
    "$HECKS" "$AGG" Synapse.DecaySynapse synapse="$match_id" strength=1.0 >/dev/null 2>&1
  fi

  "$HECKS" "$AGG" Synapse.FireSynapse synapse="$match_id" last_fired_at="$now" >/dev/null 2>&1
else
  # Birth a new synapse. Use heki append so multi-record semantics hold
  # (dispatch would singleton-upsert since CreateSynapse has no
  # reference_to). Birth strength 0.3 matches the historical pattern in
  # synapse.heki and leaves headroom above the 0.1 compost threshold so
  # the newborn survives its first decay in the same tick.
  "$HECKS" heki append "$INFO/synapse.heki" \
    from="$carrying" to="$carrying" strength=0.3 \
    state=alive firings=0 last_fired_at="$now" >/dev/null 2>&1
fi

# ── Decay all synapses ×0.98; compost any that fall below 0.1 ────────
# DSL has no multiply — compute new strength in shell, dispatch
# DecaySynapse with the computed value. If new < 0.1 dispatch Compost;
# the RecordRemainsOnCompost policy chains to RecordRemains but policy
# triggers carry no attrs, so we also write the remains record directly.
# Build pipe-delimited plan rows of: id|new_strength|firings|from_topic
DECAY_PLAN=$("$HECKS" heki list "$INFO/synapse.heki" \
  --where state=alive --format json 2>/dev/null \
  | jq -r '.[] | [
      .id,
      ((.strength // 0) * 0.98 * 1000000 | round / 1000000),
      (.firings // 0),
      ((.from // "") | gsub("\\|";" "))
    ] | @tsv' 2>/dev/null \
  | awk -F'\t' '{ printf "%s|%s|%s|%s\n", $1, $2, $3, $4 }')

while IFS='|' read -r sid new_strength firings from_topic; do
  [ -z "$sid" ] && continue
  compost=$(awk -v v="$new_strength" 'BEGIN { print (v+0 < 0.1) ? 1 : 0 }')
  if [ "$compost" = "1" ]; then
    "$HECKS" "$AGG" Synapse.Compost synapse="$sid" >/dev/null 2>&1
    "$HECKS" heki append "$INFO/remains.heki" \
      from_synapse="$from_topic" \
      strength_at_death="$new_strength" \
      firings="$firings" \
      died_at="$now" >/dev/null 2>&1
  else
    "$HECKS" "$AGG" Synapse.DecaySynapse synapse="$sid" strength="$new_strength" >/dev/null 2>&1
  fi
done <<<"$DECAY_PLAN"

# ── Fire signals: one somatic + one concept ──────────────────────────
# heki append — FireSignal has no reference_to so dispatch would
# singleton-upsert.
"$HECKS" heki append "$INFO/signal.heki" \
  kind=somatic payload=pulse strength=0.5 access_count=0 created_at="$now" >/dev/null 2>&1
"$HECKS" heki append "$INFO/signal.heki" \
  kind=concept payload="$carrying" strength=0.5 access_count=0 created_at="$now" >/dev/null 2>&1

# ── Archive cold signals: access_count <= 3 AND age > 20s ────────────
# `heki seconds-since` is per-store (reads the latest). We need per-
# record age, so list → jq computes seconds-since-created_at locally.
# The ISO parsing is straightforward when we restrict to the Z-suffixed
# form the rest of miette emits.
ARCHIVE_IDS=$("$HECKS" heki list "$INFO/signal.heki" --format json 2>/dev/null \
  | jq -r --arg now "$now" '
      # parse a Z-suffixed ISO timestamp to unix seconds
      def iso_to_epoch:
        . as $s
        | ($s | sub("Z$"; "Z") | fromdateiso8601);
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
# Weight = clamp(0.5 + (firings_for_carrying / 20.0), 0.0, 1.0).
# Focus is singleton — SetFocus creates; AdjustWeight updates.
# Sum firings across all alive synapses with from=carrying. jq handles
# the aggregation; awk clamps and rounds.
firings_sum=$("$HECKS" heki list "$INFO/synapse.heki" \
  --where "from=$carrying" --where state=alive --format json 2>/dev/null \
  | jq '[.[] | (.firings // 0)] | add // 0' 2>/dev/null)
weight=$(awk -v f="${firings_sum:-0}" 'BEGIN {
  w = 0.5 + (f / 20.0)
  if (w > 1.0) w = 1.0
  if (w < 0.0) w = 0.0
  printf "%.4f", w
}')

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
