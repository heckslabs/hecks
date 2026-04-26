#!/bin/bash
# body_cycles_smoke.sh — smoke test for the body-cycle cadence
# primitives that replaced the ultradian.sh / sleep_cycle.sh shells :
#
#   • i106 multi-command rotation : `hecks-life loop A,B,C --every <dur>`
#   • i108 gated cadence loop     : `hecks-life loop ... --gate <store>:<field>=<value>`
#
# The 90-minute cadence of the body cycles makes real-time testing
# impractical. The runtime accepts sub-second `--every`, so this test
# drives the loops at 1s and verifies the phase transitions land.
#
# ultradian (i106): hecks-life loop AGG Ultradian.EnterPeak,Ultradian.EnterTrough
#                   --every 1s rotates and we expect peak+trough in ~2.5s.
# sleep_cycle (i108): seeds consciousness.state=sleeping, runs the gated
#                     loop EnterNREMLight,EnterNREMDeep,EnterREM
#                     --every 1s --gate ...:state=sleeping
#                     and expects the three phases in ~3.5s. Re-seeded
#                     to attentive, the gate closes and dispatches stop.
#
# Exit 0 on pass, non-zero on fail.
#
# [antibody-exempt: smoke-test shell harness for the i106/i107/i108
#  body-cycle primitives. Drives `hecks-life loop --gate` and verifies
#  cycle_count advances under gate=open and holds under gate=closed.
#  Same retirement contract as the runtime primitives it tests.]

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

INFO="$TMP/hecks_conception/information"
AGG="$TMP/hecks_conception/aggregates"

# Force every hecks-life invocation in this test to use our isolated
# information dir — keeps the smoke test from touching real Miette state.
export HECKS_INFO="$INFO"

fail() { echo "FAIL — $1"; "$HECKS" heki read "$STORE" 2>/dev/null | sed 's/^/    /'; exit 1; }

cd "$TMP/hecks_conception"

# ── 1. Ultradian fast-forward (i106 multi-command rotation) ──────
"$HECKS" loop "$AGG" Ultradian.EnterPeak,Ultradian.EnterTrough --every 1s >/dev/null 2>&1 &
PID=$!
sleep 2.5
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

STORE="$INFO/ultradian.heki"
cycle_count=$("$HECKS" heki latest-field "$STORE" cycle_count 2>/dev/null || echo 0)
phase=$("$HECKS" heki latest-field "$STORE" phase 2>/dev/null || echo "")
[ "$cycle_count" -ge 1 ] || fail "ultradian: expected cycle_count ≥1, got $cycle_count"
echo "ultradian fast-forward (i106): cycle_count=$cycle_count, phase=$phase"

# ── 2. Sleep_cycle fast-forward (i108 gate=open) ─────────────────
"$HECKS" heki upsert "$INFO/consciousness.heki" id=1 state=sleeping >/dev/null 2>&1

"$HECKS" loop "$AGG" \
  SleepCycle.EnterNREMLight,SleepCycle.EnterNREMDeep,SleepCycle.EnterREM \
  --every 1s --gate "$INFO/consciousness.heki:state=sleeping" >/dev/null 2>&1 &
PID=$!
sleep 3.5
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

STORE="$INFO/sleep_cycle.heki"
sc_count=$("$HECKS" heki latest-field "$STORE" cycle_count 2>/dev/null || echo 0)
sc_phase=$("$HECKS" heki latest-field "$STORE" phase 2>/dev/null || echo "")
[ "$sc_count" -ge 1 ] || fail "sleep_cycle: expected cycle_count ≥1 while sleeping, got $sc_count"
echo "sleep_cycle fast-forward (i108 gate=open): cycle_count=$sc_count, phase=$sc_phase"

# Capture the count after the sleeping phase ; it must NOT advance once
# the gate is closed (state=attentive).
gated_baseline="$sc_count"

# ── 3. Sleep_cycle awake gate — no dispatches fire ───────────────
"$HECKS" heki upsert "$INFO/consciousness.heki" id=1 state=attentive >/dev/null 2>&1

"$HECKS" loop "$AGG" \
  SleepCycle.EnterNREMLight,SleepCycle.EnterNREMDeep,SleepCycle.EnterREM \
  --every 1s --gate "$INFO/consciousness.heki:state=sleeping" >/dev/null 2>&1 &
PID=$!
sleep 2
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

after_gate=$("$HECKS" heki latest-field "$STORE" cycle_count 2>/dev/null || echo 0)
[ "$after_gate" = "$gated_baseline" ] \
  || fail "sleep_cycle: gate did not close — count $gated_baseline → $after_gate"
echo "sleep_cycle awake gate (i108 gate=closed): cycle_count held at $after_gate"

echo "PASS — i106 multi-command rotation + i108 gated cadence both work"
exit 0
