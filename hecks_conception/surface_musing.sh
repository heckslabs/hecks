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
#
# [antibody-exempt: i37 Phase C — porting legacy python to shell +
#  hecks-life subcommands; retires when shell ports to bluebook shebang
#  form.]

DIR="$(dirname "$0")"
HECKS="$DIR/../hecks_life/target/release/hecks-life"
INFO="${HECKS_INFO:-$DIR/information}"
DWELL="${DWELL:-30}"
loop_count="${1:-1}"

# Oldest unconceived "real" musing — FIFO order by created_at (heki
# list default) across records with conceived != true. jq applies the
# same sentence-shape filter the old python did:
#   - ≥20 chars after trim
#   - contains whitespace or one of — - : . ? !
#   - not a bare snake_case identifier [a-z][a-z0-9_]*
# First match wins; idea is truncated to 80 chars.
thought=$("$HECKS" heki list "$INFO/musing.heki" --where conceived=false \
    --format json 2>/dev/null \
  | jq -r '
      [ .[]
        | (.idea // "") | tostring
        | sub("^\\s+"; "") | sub("\\s+$"; "")
        | select(length >= 20)
        | select(test("[ —\\-:.?!]"))
        | select(test("^[a-z][a-z0-9_]*$") | not)
      ]
      | .[0] // ""
      | .[0:80]' 2>/dev/null)

if [ -n "$thought" ]; then
  $HECKS heki upsert "$INFO/consciousness.heki" sleep_summary="$thought" 2>/dev/null
  # Mark conceived only every DWELL-th call. Default 30 (= ~5 min on
  # screen) so each musing gets full attention and the pool advances
  # at roughly the same rate Claude mints new ones (~5 min cadence).
  #
  # Prefix match (`idea~=$thought`) covers both cases the old Python
  # handled: `idea == thought` when idea ≤ 80 chars (thought == idea),
  # and `idea.startswith(thought)` when idea > 80 chars (thought is
  # idea truncated to 80). The redundant `target.startswith(idea[:80])`
  # clause in the old Python is a tautology when thought = idea[:80].
  if [ "$((loop_count % DWELL))" = "0" ]; then
    "$HECKS" heki mark "$INFO/musing.heki" \
      --where "conceived!=true" \
      --where "idea~=$thought" \
      --set conceived=true >/dev/null 2>&1
  fi
else
  $HECKS heki upsert "$INFO/consciousness.heki" sleep_summary="" 2>/dev/null
fi
