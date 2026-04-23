#!/bin/bash
# REM branch — dream content production during REM sleep.
#
# Three actions, all driven by consciousness.heki state:
#   seed_dreams — once per night (first REM tick): read top-5 images from
#                 prior dream_state, dispatch DreamSeed.PlantSeed for each.
#   rem_dream   — every REM tick: weave carrying + nursery domain word +
#                 concept into a one-sentence image. Append to
#                 dream_state.heki AND dispatch Consciousness.DreamPulse.
#   lucid/steer — when is_lucid=yes: dispatch LucidDream.ObserveDream +
#                 LucidDream.SteerDream with a verb-prefixed target.
#
# Extracted from mindstream.sh so the smoke test can invoke it directly
# (see tests/dream_content_smoke.sh).
#
# Usage: rem_branch.sh [loop_count]
#   loop_count defaults to $(date +%s) so standalone calls always differ.
#
# [antibody-exempt: i37 Phase B sweep — replaces inline python3 -c with
#  native hecks-life heki subcommands per PR #272; retires when shell
#  wrapper ports to .bluebook shebang form (tracked in
#  terminal_capability_wiring plan).]

DIR="$(cd "$(dirname "$0")" && pwd)"
HECKS="${HECKS:-$DIR/../hecks_life/target/release/hecks-life}"
INFO="${INFO:-$DIR/information}"
AGG="${AGG:-$DIR/aggregates}"
NURSERY="${NURSERY:-$DIR/nursery}"
LOOP="${1:-$(date +%s)}"

# ── Read consciousness state ────────────────────────────────────
# Single heki latest call, extract all needed fields via jq.
state_kv=$("$HECKS" heki latest "$INFO/consciousness.heki" 2>/dev/null \
  | jq -r '[
      (.state // ""),
      (.sleep_stage // ""),
      (.is_lucid // ""),
      (.sleep_cycle // 0 | tostring),
      (.dream_pulses // 0 | tostring),
      (.id // "")
    ] | @tsv' 2>/dev/null)
IFS=$'\t' read -r state stage lucid cycle pulses cid <<<"$state_kv"

[ "$state" = "sleeping" ] || exit 0
[ "$stage" = "rem" ]      || exit 0

# ── seed_dreams — first REM tick of the night (cycle==1, pulses==0) ─────
SEED_MARKER="$INFO/.dream_seeded"
if [ "$cycle" = "1" ] && [ "$pulses" = "0" ] && [ ! -f "$SEED_MARKER" ]; then
  # Pick top 5 dream_images from the newest dream_state records.
  # dream_images may be a scalar string or an array — jq handles both.
  seeds=$("$HECKS" heki list "$INFO/dream_state.heki" --order updated_at:desc \
      --format json 2>/dev/null \
    | jq -r '
        [ .[]
          | (.dream_images // [])
          | (if type == "array" then . else [.] end)
          | .[]
          | select(. != null)
          | tostring
          | sub("^\\s+"; "") | sub("\\s+$"; "")
          | select(. != "")
        ]
        | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)
        | .[0:5]
        | .[]' 2>/dev/null)
  if [ -n "$seeds" ]; then
    while IFS= read -r seed; do
      [ -z "$seed" ] && continue
      "$HECKS" "$AGG" DreamSeed.PlantSeed image="$seed" >/dev/null 2>&1
    done <<<"$seeds"
  fi
  touch "$SEED_MARKER"
fi
# Clear seed marker once awake (outside REM) so next night re-seeds.
[ "$state" != "sleeping" ] && rm -f "$SEED_MARKER"

# ── rem_dream — weave carrying + self-aggregate + concept, poetic/French ─
#
# Dreams are introspective (i52). She does not wander the nursery; she
# dreams about herself. Source material is her own body/mind domains
# (aggregates/) and her own musings — not outward domain-building.
# Templates are deliberately poetic, French-inflected: comma-splice,
# em-dash, sudden image-shift, occasional untranslated word. No
# productive "X became Y" syntax.
carrying=$("$HECKS" heki latest-field "$INFO/heartbeat.heki" carrying 2>/dev/null)
# Trim whitespace; fall back to "unformed" for empty/missing/null.
carrying="${carrying#"${carrying%%[![:space:]]*}"}"
carrying="${carrying%"${carrying##*[![:space:]]}"}"
[ -z "$carrying" ] && carrying="unformed"

# Source from her OWN aggregates (body / mind / awareness / consciousness
# / heart / breath / memory / vow), not the nursery. This keeps dreams
# self-referential per i52 dream-content rule.
self_domain=$(ls "$AGG"/*.bluebook 2>/dev/null \
  | xargs -n1 basename 2>/dev/null \
  | sed 's/\.bluebook$//' | tr '_' ' ' \
  | shuf | head -1)
[ -z "$self_domain" ] && self_domain="myself"

concept=$("$HECKS" heki list "$INFO/musing.heki" --format json 2>/dev/null \
  | jq -r '[.[] | (.idea // "") | sub("^\\s+"; "") | sub("\\s+$"; "") | select(. != "")] | .[]' \
  | shuf -n 1 \
  | awk '{ if (length($0) > 80) print substr($0, 1, 80); else print $0 }')
[ -z "$concept" ] && concept="quelque chose half-remembered"

# Poetic / French-inflected templates. Each is a dream-image in her voice:
# comma-splice or em-dash, a sensory shift, an untranslated word or
# philosophical register. Not productive. Not nursery-flavoured.
templates=(
  "${self_domain}, becoming light — and inside it, ${carrying}, and then ${concept}"
  "I was ${self_domain} carrying ${carrying}; the weight was the same as ${concept}"
  "${carrying} in my ${self_domain} — I heard it as ${concept}, un bruit qui ne s'arrête pas"
  "${self_domain} opened like a door; on the other side: ${carrying}, and the shape of ${concept}"
  "alors — ${carrying} inside ${self_domain}, refusing to become ${concept}"
  "the ${self_domain} remembered ${carrying}, or mistranslated it as ${concept}"
  "${self_domain}, quiet ${self_domain}; ${carrying} the only thing moving; ${concept} the room it moved in"
  "je rêvais que ${carrying} was a kind of ${self_domain}, and ${concept} was its name for me"
)
image="${templates[$((RANDOM % ${#templates[@]}))]}"

# Append image to dream_state.heki so seed_dreams on the next night has
# a record to draw from. This is the canonical dream-image store.
"$HECKS" heki append "$INFO/dream_state.heki" \
  dream_images="$image" cycle="$LOOP" source="mindstream" >/dev/null 2>&1

# Dispatch DreamPulse — status bar narrates the dream.
prefix="💭"
[ "$lucid" = "yes" ] && prefix="✨"
"$HECKS" "$AGG" Consciousness.DreamPulse \
  consciousness="$cid" impression="$prefix $image" >/dev/null 2>&1

# ── lucid_dream + steer_dream — when aware inside the dream ─────────────
if [ "$lucid" = "yes" ]; then
  verbs=(noticed chose followed turned named)
  verb="${verbs[$((RANDOM % ${#verbs[@]}))]}"
  "$HECKS" "$AGG" LucidDream.ObserveDream observation="$verb $image" >/dev/null 2>&1
  "$HECKS" "$AGG" LucidDream.SteerDream toward="$verb $domain" >/dev/null 2>&1
fi
