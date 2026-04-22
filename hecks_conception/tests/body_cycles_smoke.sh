#!/bin/bash
# body_cycles_smoke.sh — smoke test for the ULTRADIAN_TICK and
# SLEEP_CYCLE_TICK env overrides on ultradian.sh and sleep_cycle.sh.
#
# The 90-minute cadence of these daemons makes real-time testing
# impractical. Each daemon reads its own *_TICK env var; this test
# drives both at 1s and verifies the phase transitions land.
#
# ultradian.sh: expects PeakEntered → TroughEntered → PeakEntered
#               within ~3s.
# sleep_cycle.sh: seeds consciousness.state=sleeping, expects
#                 NREMLightEntered → NREMDeepEntered → REMEntered
#                 within ~3.5s. Then seeds state=attentive and
#                 verifies the daemon enters its 60s idle loop
#                 without firing further Enter* commands.
#
# Exit 0 on pass, non-zero on fail.

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"

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

TMP=$(mktemp -d -t body_cycles_smoke.XXXXXX)
trap "rm -rf $TMP" EXIT

mkdir -p "$TMP/hecks_conception/information" "$TMP/hecks_conception/aggregates"
mkdir -p "$TMP/hecks_life/target/release"
ln -sf "$HECKS" "$TMP/hecks_life/target/release/hecks-life"
ln -sf "$CONCEPT_DIR/aggregates/"*.bluebook "$TMP/hecks_conception/aggregates/"
cp "$CONCEPT_DIR/ultradian.sh" "$TMP/hecks_conception/ultradian.sh"
cp "$CONCEPT_DIR/sleep_cycle.sh" "$TMP/hecks_conception/sleep_cycle.sh"

fail() { echo "FAIL — $1"; cat "$LOG" 2>/dev/null | sed 's/^/    /'; exit 1; }

cd "$TMP/hecks_conception"

# ── 1. Ultradian fast-forward ────────────────────────────────────
LOG=$(mktemp)
ULTRADIAN_TICK=1 bash ./ultradian.sh > "$LOG" 2>&1 &
PID=$!
sleep 2.5
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

peaks=$(grep -c '"phase":"peak"' "$LOG" || true)
troughs=$(grep -c '"phase":"trough"' "$LOG" || true)
[ "$peaks" -ge 1 ] || fail "ultradian: expected ≥1 PeakEntered, got $peaks"
[ "$troughs" -ge 1 ] || fail "ultradian: expected ≥1 TroughEntered, got $troughs"
echo "ultradian fast-forward: $peaks peak(s), $troughs trough(s) in 2.5s"

# ── 2. Sleep_cycle fast-forward (sleeping) ───────────────────────
"$HECKS" heki upsert "$TMP/hecks_conception/information/consciousness.heki" \
  id=1 state=sleeping >/dev/null 2>&1

LOG=$(mktemp)
SLEEP_CYCLE_TICK=1 bash ./sleep_cycle.sh > "$LOG" 2>&1 &
PID=$!
sleep 3.5
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

light=$(grep -c '"phase":"nrem_light"' "$LOG" || true)
deep=$(grep -c '"phase":"nrem_deep"' "$LOG" || true)
rem=$(grep -c '"phase":"rem"' "$LOG" || true)
[ "$light" -ge 1 ] || fail "sleep_cycle: expected ≥1 NREMLightEntered while sleeping, got $light"
[ "$deep" -ge 1 ] || fail "sleep_cycle: expected ≥1 NREMDeepEntered while sleeping, got $deep"
[ "$rem" -ge 1 ] || fail "sleep_cycle: expected ≥1 REMEntered while sleeping, got $rem"
echo "sleep_cycle fast-forward (sleeping): $light light, $deep deep, $rem REM in 3.5s"

# ── 3. Sleep_cycle awake gate — no commands fire ─────────────────
"$HECKS" heki upsert "$TMP/hecks_conception/information/consciousness.heki" \
  id=1 state=attentive >/dev/null 2>&1

LOG=$(mktemp)
SLEEP_CYCLE_TICK=1 bash ./sleep_cycle.sh > "$LOG" 2>&1 &
PID=$!
sleep 2
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

awake_dispatches=$(grep -c '"aggregate":"SleepCycle"' "$LOG" || true)
[ "$awake_dispatches" -eq 0 ] \
  || fail "sleep_cycle: expected 0 dispatches while awake, got $awake_dispatches"
echo "sleep_cycle awake gate: 0 dispatches in 2s (correct)"

echo "PASS — fast-forward mode works for both ultradian and sleep_cycle"
exit 0
