#!/bin/bash
# pulse_organs_smoke.sh — smoke test for pulse_organs.sh.
#
# Copies hecks_conception/information/*.heki to a tmpdir, points
# pulse_organs.sh at it via HECKS_INFO / HECKS_AGG, runs 10 ticks, and
# asserts the organ stores grew.
#
# Assertions:
#   - synapse.heki has at least 1 record
#   - remains.heki exists
#   - signal.heki has > 1 record (so at least one tick appended signals)
#   - focus.heki has a record
#
# Exit 0 on pass, non-zero on fail.

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"

# Find the hecks-life binary. Prefer HECKS_BIN override; otherwise the
# worktree's own build, then the main checkout's build.
if [ -n "${HECKS_BIN:-}" ]; then
  HECKS="$HECKS_BIN"
elif [ -x "$REPO_ROOT/hecks_life/target/release/hecks-life" ]; then
  HECKS="$REPO_ROOT/hecks_life/target/release/hecks-life"
elif [ -x "/Users/christopheryoung/Projects/hecks/hecks_life/target/release/hecks-life" ]; then
  HECKS="/Users/christopheryoung/Projects/hecks/hecks_life/target/release/hecks-life"
else
  echo "FAIL — can't find hecks-life binary"
  exit 2
fi

TMP=$(mktemp -d -t pulse_organs_smoke.XXXXXX)
trap "rm -rf $TMP" EXIT

mkdir -p "$TMP/information" "$TMP/aggregates"

# Link aggregates so dispatch finds the organs/awareness/etc bluebooks.
ln -sf "$CONCEPT_DIR/aggregates/"*.bluebook "$TMP/aggregates/"

# *.world pins the heki dir — the runtime reads it.
cat > "$TMP/pulse_organs_smoke.world" <<'EOF'
Hecks.world "PulseOrgansSmoke" do
  heki do
    dir "information"
  end
end
EOF

# Seed: copy the heki files the script reads (heartbeat / consciousness /
# awareness). Do NOT copy organ stores — we want to prove pulse_organs.sh
# creates them from scratch.
for f in heartbeat consciousness awareness; do
  src="$CONCEPT_DIR/information/${f}.heki"
  [ -f "$src" ] && cp "$src" "$TMP/information/${f}.heki"
done

# Seed two synapses so the test exercises both decay paths:
#   - one healthy enough to survive (strength=0.5)
#   - one weak enough to compost on first decay (0.1 × 0.98 = 0.098 < 0.1)
"$HECKS" heki append "$TMP/information/synapse.heki" \
  from=alpha to=beta strength=0.5 state=alive firings=2 \
  last_fired_at=2026-04-20T00:00:00Z >/dev/null 2>&1
"$HECKS" heki append "$TMP/information/synapse.heki" \
  from=fading to=memory strength=0.1 state=alive firings=1 \
  last_fired_at=2026-04-20T00:00:00Z >/dev/null 2>&1

fail() { echo "FAIL — $1"; exit 1; }

# 10 pulses.
for i in 1 2 3 4 5 6 7 8 9 10; do
  HECKS_INFO="$TMP/information" \
  HECKS_AGG="$TMP/aggregates" \
  HECKS_BIN="$HECKS" \
  bash "$CONCEPT_DIR/pulse_organs.sh" \
    || fail "pulse_organs.sh exited non-zero on tick $i"
done

count_records() {
  [ ! -f "$1" ] && { echo 0; return; }
  "$HECKS" heki read "$1" 2>/dev/null \
    | python3 -c "import json,sys
try: print(len(json.load(sys.stdin) or {}))
except Exception: print(0)" 2>/dev/null
}

synapse_count=$(count_records "$TMP/information/synapse.heki")
signal_count=$(count_records "$TMP/information/signal.heki")
focus_count=$(count_records "$TMP/information/focus.heki")
remains_count=$(count_records "$TMP/information/remains.heki")

echo "After 10 pulses:"
echo "  synapse records: $synapse_count"
echo "  signal records:  $signal_count"
echo "  focus records:   $focus_count"
echo "  remains records: $remains_count"

[ "$synapse_count" -ge 1 ] || fail "synapse.heki has no records"
[ -f "$TMP/information/remains.heki" ] || fail "remains.heki was not created"
[ "$signal_count" -gt 1 ] || fail "signal.heki should have >1 record (got $signal_count)"
[ "$focus_count" -ge 1 ] || fail "focus.heki has no records"

echo "PASS — pulse_organs.sh grows synapse/signal/focus/remains as expected"
exit 0
