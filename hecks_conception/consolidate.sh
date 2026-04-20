#!/bin/bash
# consolidate.sh — periodic memory consolidation for Miette's organs.
#
# Runs every ~60 ticks (see mindstream.sh). Three passes:
#
#   1. SIGNAL → MEMORY
#      Cold signals (access_count <= 3 AND age > 60s) get promoted into
#      long-term memory (Memory.StoreMemory via heki append) and then
#      archived in place (Signal.ArchiveSignal). The short-term working
#      set thins, but nothing is lost.
#
#   2. SYNAPSE → REMAINS
#      Synapses whose strength fell below 0.1 are composted
#      (Synapse.Compost) and a Remains row is written
#      (Remains.RecordRemains via heki append) capturing last strength
#      and firing count so the body remembers what once mattered.
#
#   3. MUSING → MUSING_ARCHIVE
#      Live musings are grouped by concept (thinking_source first, then
#      feeling_source). If a concept has more than 3 live musings, the
#      oldest is archived via Entry.Archive — idea, source, concept,
#      reason ("duplicate_concept"), and timestamp — so the active pool
#      stays varied.
#
# Environment overrides (smoke tests):
#   HECKS_INFO  — alternate information directory (default: ./information)
#   HECKS_AGG   — alternate aggregates directory (default: ./aggregates)
#   HECKS_BIN   — alternate hecks-life binary
#
# Dispatch vs heki append — same pattern as pulse_organs.sh: commands
# with reference_to use dispatch with an id kwarg; "Create"-style
# commands without a reference (StoreMemory, RecordRemains, Archive)
# would singleton-upsert if dispatched, so we use `heki append` to
# preserve multi-record semantics.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
INFO="${HECKS_INFO:-$DIR/information}"
AGG="${HECKS_AGG:-$DIR/aggregates}"
HECKS="${HECKS_BIN:-$DIR/../hecks_life/target/release/hecks-life}"

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

promoted_signals=0
composted_synapses=0
archived_musings=0

# ── 1. SIGNAL → MEMORY ───────────────────────────────────────────────
# Read signal.heki, pick rows with access_count <= 3 AND age > 60s AND
# kind != archived. For each: append to store.heki (Memory.StoreMemory
# schema), then dispatch Signal.ArchiveSignal.

if [ -f "$INFO/signal.heki" ]; then
  PROMOTE_PLAN=$(HECKS_BIN="$HECKS" INFO="$INFO" python3 -c "
import json, os, subprocess
from datetime import datetime, timezone
def parse(ts):
    try:
        if ts.endswith('Z'): ts = ts[:-1] + '+00:00'
        return datetime.fromisoformat(ts)
    except Exception: return None
now = datetime.now(timezone.utc)
try:
    out = subprocess.check_output([os.environ['HECKS_BIN'],'heki','read',
        f\"{os.environ['INFO']}/signal.heki\"], stderr=subprocess.DEVNULL).decode()
    d = json.loads(out) or {}
    for k, v in d.items():
        if v.get('kind') == 'archived': continue
        ac = int(v.get('access_count', 0) or 0)
        if ac > 3: continue
        ts = parse(v.get('created_at',''))
        if ts is None: continue
        if (now - ts).total_seconds() <= 60: continue
        kind = (v.get('kind') or '').replace('|',' ')
        payload = (v.get('payload') or '').replace('|',' ')
        created_at = v.get('created_at','')
        print(f'{k}|{kind}|{payload}|{created_at}')
except Exception: pass" 2>/dev/null)

  while IFS='|' read -r sid kind payload created_at; do
    [ -z "$sid" ] && continue
    "$HECKS" heki append "$INFO/store.heki" \
      kind="$kind" payload="$payload" source=signal \
      created_at="$created_at" >/dev/null 2>&1
    "$HECKS" "$AGG" Signal.ArchiveSignal signal="$sid" >/dev/null 2>&1
    promoted_signals=$((promoted_signals + 1))
  done <<<"$PROMOTE_PLAN"
fi

# ── 2. SYNAPSE → REMAINS ─────────────────────────────────────────────
# Composting also happens in pulse_organs.sh on decay, but a periodic
# sweep catches any alive synapse that slipped below 0.1 without being
# caught (e.g. if decay was skipped).

if [ -f "$INFO/synapse.heki" ]; then
  COMPOST_PLAN=$(HECKS_BIN="$HECKS" INFO="$INFO" python3 -c "
import json, os, subprocess
try:
    out = subprocess.check_output([os.environ['HECKS_BIN'],'heki','read',
        f\"{os.environ['INFO']}/synapse.heki\"], stderr=subprocess.DEVNULL).decode()
    d = json.loads(out) or {}
    for k, v in d.items():
        if v.get('state','alive') != 'alive': continue
        s = float(v.get('strength', 0.0) or 0.0)
        if s >= 0.1: continue
        firings = int(v.get('firings', 0) or 0)
        from_t = (v.get('from') or '').replace('|',' ')
        print(f'{k}|{s}|{firings}|{from_t}')
except Exception: pass" 2>/dev/null)

  while IFS='|' read -r sid strength firings from_topic; do
    [ -z "$sid" ] && continue
    "$HECKS" "$AGG" Synapse.Compost synapse="$sid" >/dev/null 2>&1
    "$HECKS" heki append "$INFO/remains.heki" \
      from_synapse="$from_topic" \
      strength_at_death="$strength" \
      firings="$firings" \
      died_at="$now" >/dev/null 2>&1
    composted_synapses=$((composted_synapses + 1))
  done <<<"$COMPOST_PLAN"
fi

# ── 3. MUSING → MUSING_ARCHIVE ───────────────────────────────────────
# Group live musings (conceived != true) by concept. When more than 3
# share a concept, archive the oldest one (by created_at if present,
# else first-seen order). Archive via heki append to entry.heki.

if [ -f "$INFO/musing.heki" ]; then
  ARCHIVE_PLAN=$(HECKS_BIN="$HECKS" INFO="$INFO" python3 -c "
import json, os, subprocess
from collections import defaultdict
try:
    out = subprocess.check_output([os.environ['HECKS_BIN'],'heki','read',
        f\"{os.environ['INFO']}/musing.heki\"], stderr=subprocess.DEVNULL).decode()
    d = json.loads(out) or {}
    buckets = defaultdict(list)
    for k, v in d.items():
        if v.get('conceived') is True: continue
        if v.get('status') == 'archived': continue
        concept = (v.get('thinking_source') or v.get('feeling_source')
                   or v.get('source') or '').strip()
        if not concept: continue
        created = v.get('created_at','')
        buckets[concept].append((created, k, v))
    for concept, rows in buckets.items():
        if len(rows) <= 3: continue
        rows.sort(key=lambda r: r[0] or '')
        oldest_created, oldest_id, oldest = rows[0]
        idea = (oldest.get('idea') or '').replace('|',' ')
        src = (oldest.get('source') or 'mindstream').replace('|',' ')
        c = concept.replace('|',' ')
        print(f'{oldest_id}|{idea}|{src}|{c}')
except Exception: pass" 2>/dev/null)

  while IFS='|' read -r mid idea source concept; do
    [ -z "$mid" ] && continue
    "$HECKS" heki append "$INFO/musing_archive.heki" \
      idea="$idea" source="$source" concept="$concept" \
      archived_reason="duplicate_concept" archived_at="$now" >/dev/null 2>&1
    # Mark the original musing archived so it's not re-counted next sweep.
    python3 - "$INFO/musing.heki" "$mid" <<'PY' >/dev/null 2>&1
import json, sys, subprocess, os
heki, mid = sys.argv[1], sys.argv[2]
binp = os.environ.get('HECKS_BIN') or \
       os.path.expanduser('~/Projects/hecks/hecks_life/target/release/hecks-life')
out = subprocess.check_output([binp,'heki','read',heki],
                              stderr=subprocess.DEVNULL).decode()
d = json.loads(out) or {}
r = d.get(mid)
if r is None: sys.exit(0)
r['status'] = 'archived'
subprocess.run([binp,'heki','append',heki] +
               [f"{k}={v}" for k, v in r.items() if isinstance(v, (str,int,float,bool))],
               check=False)
PY
    archived_musings=$((archived_musings + 1))
  done <<<"$ARCHIVE_PLAN"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo "consolidate: promoted=$promoted_signals composted=$composted_synapses archived=$archived_musings"
exit 0
