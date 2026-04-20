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

DIR="$(cd "$(dirname "$0")" && pwd)"
HECKS="${HECKS:-$DIR/../hecks_life/target/release/hecks-life}"
INFO="${INFO:-$DIR/information}"
AGG="${AGG:-$DIR/aggregates}"
NURSERY="${NURSERY:-$DIR/nursery}"
LOOP="${1:-$(date +%s)}"

# ── Read consciousness state ────────────────────────────────────
state_json=$("$HECKS" heki latest "$INFO/consciousness.heki" 2>/dev/null)
state=$(echo "$state_json"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state',''))" 2>/dev/null)
stage=$(echo "$state_json"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('sleep_stage',''))" 2>/dev/null)
lucid=$(echo "$state_json"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('is_lucid',''))" 2>/dev/null)
cycle=$(echo "$state_json"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('sleep_cycle',0))" 2>/dev/null)
pulses=$(echo "$state_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('dream_pulses',0))" 2>/dev/null)
cid=$(echo "$state_json"    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null)

[ "$state" = "sleeping" ] || exit 0
[ "$stage" = "rem" ]      || exit 0

# ── seed_dreams — first REM tick of the night (cycle==1, pulses==0) ─────
SEED_MARKER="$INFO/.dream_seeded"
if [ "$cycle" = "1" ] && [ "$pulses" = "0" ] && [ ! -f "$SEED_MARKER" ]; then
  # Pick top 5 dream_images from the newest dream_state records.
  seeds=$("$HECKS" heki read "$INFO/dream_state.heki" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    rows = sorted(d.values(), key=lambda r: r.get('updated_at',''), reverse=True)
    seen = set(); out = []
    for r in rows:
        for img in r.get('dream_images', []) or []:
            img = (img or '').strip()
            if img and img not in seen:
                seen.add(img); out.append(img)
        if len(out) >= 5: break
    for img in out[:5]: print(img)
except Exception:
    pass
" 2>/dev/null)
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

# ── rem_dream — weave carrying + nursery domain + concept ───────────────
carrying=$("$HECKS" heki latest "$INFO/heartbeat.heki" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('carrying') or 'unformed').strip() or 'unformed')" 2>/dev/null)
domain=$(ls "$NURSERY" 2>/dev/null | shuf | head -1 | tr '_' ' ')
concept=$("$HECKS" heki read "$INFO/musing.heki" 2>/dev/null | python3 -c "
import json, sys, random
try:
    d = json.load(sys.stdin)
    ideas = [ (v.get('idea','') or '').strip() for v in d.values() if (v.get('idea') or '').strip() ]
    print(random.choice(ideas)[:80] if ideas else 'something half-remembered')
except Exception:
    print('something half-remembered')
" 2>/dev/null)
templates=(
  "${carrying} became ${domain}, which ${concept}"
  "${carrying} folded into ${domain}; ${concept}"
  "in the shape of ${domain}: ${carrying}, then ${concept}"
  "${domain} holding ${carrying} — ${concept}"
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
