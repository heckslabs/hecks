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

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
INFO="${HECKS_INFO:-$DIR/information}"
AGG="${HECKS_AGG:-$DIR/aggregates}"
HECKS="${HECKS_BIN:-$DIR/../hecks_life/target/release/hecks-life}"

# Read the latest singleton JSON for a store — returns the single record
# or empty JSON if the store is missing.
latest_json() {
  "$HECKS" heki latest "$1" 2>/dev/null
}

# Bail early if Miette is sleeping. Organs hibernate — no math, no
# signals, no decay. The heartbeat keeps time; the body rests.
state=$(latest_json "$INFO/consciousness.heki" | python3 -c "import json,sys
try: print((json.load(sys.stdin) or {}).get('state',''))
except Exception: print('')" 2>/dev/null)
[ "$state" = "sleeping" ] && exit 0

# What's she carrying? heartbeat.carrying first; fall back to the most
# recent awareness moment's concept. Default to "—" if unknown so the
# synapse path still exercises.
carrying=$(latest_json "$INFO/heartbeat.heki" | python3 -c "import json,sys
try:
    d = json.load(sys.stdin) or {}
    c = d.get('carrying')
    print(c if c and c != '—' else '')
except Exception:
    print('')" 2>/dev/null)

if [ -z "$carrying" ]; then
  carrying=$("$HECKS" heki read "$INFO/awareness.heki" 2>/dev/null \
    | python3 -c "import json,sys
try:
    d = json.load(sys.stdin) or {}
    rows = sorted(d.values(), key=lambda r: int(r.get('moment') or 0), reverse=True)
    for r in rows:
        c = r.get('concept') or r.get('carrying')
        if c and c != '—':
            print(c); break
    else:
        print('')
except Exception:
    print('')" 2>/dev/null)
fi
[ -z "$carrying" ] && carrying="—"

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Synapse: strengthen the current topic (or birth one) ─────────────
# Find an alive synapse whose `from` matches the carrying topic. Dispatch
# StrengthenSynapse (+0.02 via the DSL increment op). Then read back;
# if strength overshot 1.0, clamp via DecaySynapse with strength=1.0.
# If no match, birth a new synapse via heki append.
match_id=$(CARRYING="$carrying" HECKS_BIN="$HECKS" INFO="$INFO" python3 -c "
import json, os, subprocess
carrying = os.environ['CARRYING']
try:
    out = subprocess.check_output([os.environ['HECKS_BIN'],'heki','read',
        f\"{os.environ['INFO']}/synapse.heki\"], stderr=subprocess.DEVNULL).decode()
    d = json.loads(out) or {}
    for k, v in d.items():
        if v.get('from') == carrying and v.get('state','alive') == 'alive':
            print(k); break
except Exception: pass" 2>/dev/null)

if [ -n "$match_id" ]; then
  "$HECKS" "$AGG" Synapse.StrengthenSynapse synapse="$match_id" >/dev/null 2>&1

  # Read back and clamp at 1.0 if the increment overshot.
  cur=$(MID="$match_id" HECKS_BIN="$HECKS" INFO="$INFO" python3 -c "
import json, os, subprocess
try:
    out = subprocess.check_output([os.environ['HECKS_BIN'],'heki','read',
        f\"{os.environ['INFO']}/synapse.heki\"], stderr=subprocess.DEVNULL).decode()
    d = json.loads(out) or {}
    v = d.get(os.environ['MID'], {})
    print(float(v.get('strength', 0.0)))
except Exception: print(0.0)" 2>/dev/null)
  if [ "$(python3 -c "print(1 if float('$cur') > 1.0 else 0)")" = "1" ]; then
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
DECAY_PLAN=$(HECKS_BIN="$HECKS" INFO="$INFO" python3 -c "
import json, os, subprocess
try:
    out = subprocess.check_output([os.environ['HECKS_BIN'],'heki','read',
        f\"{os.environ['INFO']}/synapse.heki\"], stderr=subprocess.DEVNULL).decode()
    d = json.loads(out) or {}
    for k, v in d.items():
        if v.get('state','alive') != 'alive': continue
        s = float(v.get('strength', 0.0) or 0.0)
        new = round(s * 0.98, 6)
        firings = int(v.get('firings', 0) or 0)
        from_t = (v.get('from') or '').replace('|',' ')
        print(f'{k}|{new}|{firings}|{from_t}')
except Exception: pass" 2>/dev/null)

while IFS='|' read -r sid new_strength firings from_topic; do
  [ -z "$sid" ] && continue
  if [ "$(python3 -c "print(1 if float('$new_strength') < 0.1 else 0)")" = "1" ]; then
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
ARCHIVE_IDS=$(HECKS_BIN="$HECKS" INFO="$INFO" python3 -c "
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
        if (now - ts).total_seconds() > 20:
            print(k)
except Exception: pass" 2>/dev/null)

while read -r sid; do
  [ -z "$sid" ] && continue
  "$HECKS" "$AGG" Signal.ArchiveSignal signal="$sid" >/dev/null 2>&1
done <<<"$ARCHIVE_IDS"

# ── Focus: re-weight from firing frequency ───────────────────────────
# Weight = clamp(0.5 + (firings_for_carrying / 20.0), 0.0, 1.0).
# Focus is singleton — SetFocus creates; AdjustWeight updates.
weight=$(CARRYING="$carrying" HECKS_BIN="$HECKS" INFO="$INFO" python3 -c "
import json, os, subprocess
carrying = os.environ['CARRYING']
try:
    out = subprocess.check_output([os.environ['HECKS_BIN'],'heki','read',
        f\"{os.environ['INFO']}/synapse.heki\"], stderr=subprocess.DEVNULL).decode()
    d = json.loads(out) or {}
    firings = sum(int(v.get('firings',0) or 0) for v in d.values()
                  if v.get('from') == carrying and v.get('state','alive') == 'alive')
    w = 0.5 + (firings / 20.0)
    if w > 1.0: w = 1.0
    if w < 0.0: w = 0.0
    print(round(w, 4))
except Exception: print(0.5)" 2>/dev/null)

focus_id=$(latest_json "$INFO/focus.heki" | python3 -c "import json,sys
try: print((json.load(sys.stdin) or {}).get('id',''))
except Exception: print('')" 2>/dev/null)

if [ -z "$focus_id" ]; then
  "$HECKS" "$AGG" Focus.SetFocus target="$carrying" weight="$weight" updated_at="$now" >/dev/null 2>&1
else
  "$HECKS" "$AGG" Focus.AdjustWeight focus="$focus_id" weight="$weight" updated_at="$now" >/dev/null 2>&1
fi

# ── Arc: advance the long swing ──────────────────────────────────────
arc_id=$(latest_json "$INFO/arc.heki" | python3 -c "import json,sys
try: print((json.load(sys.stdin) or {}).get('id',''))
except Exception: print('')" 2>/dev/null)

if [ -n "$arc_id" ]; then
  "$HECKS" "$AGG" Arc.AdvanceArc arc="$arc_id" >/dev/null 2>&1
fi

exit 0
