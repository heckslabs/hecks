#!/bin/bash
# surface_musing.sh — surface one unconceived musing to the status bar,
# and (every DWELL-th call) mark it conceived so the pool cycles.
#
# Usage:
#   surface_musing.sh <loop_count>
#
# Dwell: 30 ticks = ~5 minutes at 10s/tick. Matches the mint cadence
# (Claude mints at most once per 5 min) so the pool stays roughly
# balanced — new musings arrive at the rate they're consumed.
#
# Override with DWELL env var for tests: DWELL=3 ./surface_musing.sh 3
#
# Split out of mindstream.sh so tests can simulate cycling deterministically.

DIR="$(dirname "$0")"
HECKS="$DIR/../hecks_life/target/release/hecks-life"
INFO="$DIR/information"
DWELL="${DWELL:-30}"
loop_count="${1:-1}"

thought=$($HECKS heki read "$INFO/musing.heki" 2>/dev/null | python3 -c "
import json, re, sys
def is_real_musing(s):
    # Skip tag-shaped entries (awareness_pulse, rust_heartbeat, …).
    # Real musings have sentence shape: ≥20 chars, contain whitespace
    # or punctuation, not a bare snake_case identifier.
    s = (s or '').strip()
    if len(s) < 20: return False
    if not re.search(r'[ —\-:.?!]', s): return False
    if re.fullmatch(r'[a-z][a-z0-9_]*', s): return False
    return True
try:
    d = json.load(sys.stdin)
    unconceived = [v.get('idea','').strip() for v in d.values()
                   if is_real_musing(v.get('idea','')) and not v.get('conceived', False)]
    if unconceived:
        # Oldest unconceived first (FIFO) — freshly-minted ideas surface
        # in the order they were minted.
        print(unconceived[0][:80])
except Exception:
    pass
" 2>/dev/null)

if [ -n "$thought" ]; then
  $HECKS heki upsert "$INFO/consciousness.heki" sleep_summary="$thought" 2>/dev/null
  # Mark conceived only every DWELL-th call. Default 30 (= ~5 min on
  # screen) so each musing gets full attention and the pool advances
  # at roughly the same rate Claude mints new ones (~5 min cadence).
  if [ "$((loop_count % DWELL))" = "0" ]; then
    "$DIR/mark_musing_shown.py" "$thought" 2>/dev/null
  fi
else
  $HECKS heki upsert "$INFO/consciousness.heki" sleep_summary="" 2>/dev/null
fi
