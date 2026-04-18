#!/bin/bash
# surface_musing.sh — surface one unconceived musing to the status bar,
# and (every 3rd call) mark it conceived so the pool cycles.
#
# Usage:
#   surface_musing.sh <loop_count>
#
# Called once per daemon tick. When loop_count is divisible by 3
# (~30 seconds dwell at 10s/tick), the surfaced musing is marked
# conceived and the pool advances on the next call.
#
# Split out of mindstream.sh so tests can simulate cycling deterministically.

DIR="$(dirname "$0")"
HECKS="$DIR/../hecks_life/target/release/hecks-life"
INFO="$DIR/information"
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
  # Mark conceived only every 3rd call (~30s on screen) so each musing
  # has time to be read before the pool advances.
  if [ "$((loop_count % 3))" = "0" ]; then
    "$DIR/mark_musing_shown.py" "$thought" 2>/dev/null
  fi
else
  $HECKS heki upsert "$INFO/consciousness.heki" sleep_summary="" 2>/dev/null
fi
