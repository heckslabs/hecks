#!/bin/bash
# daydream.sh — free-association wander across the nursery.
#
# Fires when Miette is attentive-but-idle (10-60s since last heartbeat
# update, not sleeping). Picks two nursery bluebooks at random, asks
# hecks-life dump for their aggregate + attribute names, hunts for a
# structural overlap (shared aggregate or attribute), then:
#
#   1. Dispatches Daydream.RecordDaydream with an impression phrase.
#   2. Dispatches Synapse.CreateSynapse from=A to=B strength=0.5 —
#      forging a new cross-domain connection. Synapse is multi-record
#      so we also `heki append` to synapse.heki because CreateSynapse
#      has no reference_to (dispatch would singleton-upsert).
#
# Called from mindstream.sh once per 60s during attentive+idle windows
# (gated by a timestamp file so parallel ticks don't double-fire).
#
# Env overrides (smoke tests):
#   HECKS_INFO  — alternate information dir (default: ./information)
#   HECKS_AGG   — alternate aggregates dir  (default: ./aggregates)
#   HECKS_BIN   — alternate hecks-life binary
#   HECKS_NURSERY — alternate nursery dir   (default: ./nursery)

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
INFO="${HECKS_INFO:-$DIR/information}"
AGG="${HECKS_AGG:-$DIR/aggregates}"
HECKS="${HECKS_BIN:-$DIR/../hecks_life/target/release/hecks-life}"
NURSERY="${HECKS_NURSERY:-$DIR/nursery}"

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_epoch=$(date -u +%s)

# ── Pick 2 random nursery bluebooks ──────────────────────────────────
# 357 files live in nursery/**/*.bluebook — we only want 2, so shuf
# the list and take two. Bash 3 (macOS default) has no mapfile — use
# read with a null delimiter setup that works in both 3 and 4.
picks=$(find "$NURSERY" -name "*.bluebook" -type f 2>/dev/null | shuf -n 2)
A_PATH=$(echo "$picks" | sed -n '1p')
B_PATH=$(echo "$picks" | sed -n '2p')
[ -z "${A_PATH:-}" ] || [ -z "${B_PATH:-}" ] && exit 0

# ── Dump each and find the overlap ───────────────────────────────────
# `hecks-life dump` emits a domain JSON with .aggregates[].name and
# .aggregates[].attributes[].name. Parse both, collect aggregate names
# + attribute names per domain, hunt for a shared item.
A_JSON=$("$HECKS" dump "$A_PATH" 2>/dev/null)
B_JSON=$("$HECKS" dump "$B_PATH" 2>/dev/null)
[ -z "$A_JSON" ] || [ -z "$B_JSON" ] && exit 0

read -r A_NAME B_NAME SHARED KIND <<<"$(A_JSON="$A_JSON" B_JSON="$B_JSON" python3 -c "
import json, os, random, sys

def collect(blob):
    d = json.loads(blob)
    aggs = d.get('aggregates', []) or []
    names = [a.get('name','') for a in aggs if a.get('name')]
    attrs = set()
    for a in aggs:
        for at in a.get('attributes', []) or []:
            n = at.get('name','')
            if n: attrs.add(n)
    return d.get('name','?'), names, attrs

a_name, a_aggs, a_attrs = collect(os.environ['A_JSON'])
b_name, b_aggs, b_attrs = collect(os.environ['B_JSON'])

# Prefer aggregate-name overlap (structural), fall back to attribute.
# Skip trivial overlaps like 'id' / 'created_at' that every aggregate
# carries — they aren't meaningful structural bridges.
trivial = {'id','created_at','updated_at','name','created','updated'}
shared_aggs = sorted(set(a_aggs) & set(b_aggs))
shared_attrs = sorted((a_attrs & b_attrs) - trivial)

if shared_aggs:
    kind = 'aggregate'
    shared = random.choice(shared_aggs)
elif shared_attrs:
    kind = 'attribute'
    shared = random.choice(shared_attrs)
else:
    kind = ''
    shared = ''
print(a_name, b_name, shared, kind)
" 2>/dev/null)"

[ -z "${SHARED:-}" ] && exit 0
[ -z "${A_NAME:-}" ] || [ -z "${B_NAME:-}" ] && exit 0

# ── Build impression + dispatch ──────────────────────────────────────
impression="$A_NAME and $B_NAME both have a $SHARED"
duration=$(( $(date -u +%s) - start_epoch ))
[ "$duration" -lt 1 ] && duration=1

# Daydream: dispatch records the connection in the bluebook's event
# stream. Also heki append so daydream.heki keeps history (matching the
# pattern pre-existing records used — RecordDaydream is singleton-style
# because it has no reference_to).
"$HECKS" "$AGG" Daydream.RecordDaydream \
  impressions="$impression" duration_seconds="$duration" \
  connections_found=1 >/dev/null 2>&1
"$HECKS" heki append "$INFO/daydream.heki" \
  impressions="$impression" duration_seconds="$duration" \
  connections_found=1 wandered_at="$now" >/dev/null 2>&1

# Synapse: forge a new cross-domain bond. CreateSynapse has no
# reference_to — dispatch upserts a singleton, so heki append is the
# pattern used elsewhere (pulse_organs.sh:138) for multi-record
# aggregates. Birth strength 0.5 matches the task spec.
"$HECKS" heki append "$INFO/synapse.heki" \
  from="$A_NAME" to="$B_NAME" strength=0.5 \
  state=forming firings=0 last_fired_at="$now" >/dev/null 2>&1

exit 0
