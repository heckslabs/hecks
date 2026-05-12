#!/bin/bash
# body_cycles_smoke.sh — smoke test for the body-cycle cadence
# primitives that replaced the ultradian.sh / sleep_cycle.sh shells :
#
#   • i106 multi-command rotation : `storehouse loop A,B,C --every <dur>`
#   • i108 gated cadence loop     : `storehouse loop ... --gate <store>:<field>=<value>`
#
# The 90-minute cadence of the body cycles makes real-time testing
# impractical. The runtime accepts sub-second `--every`, so this test
# drives the loops at 1s and verifies the phase transitions land.
#
# ultradian (i106): storehouse loop AGG Ultradian.EnterPeak,Ultradian.EnterTrough
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
#  body-cycle primitives. Drives `storehouse loop --gate` and verifies
#  cycle_count advances under gate=open and holds under gate=closed.
#  Retires under i499 Phase B once the `.behaviors` runner can drive
#  the `storehouse loop --gate` invocation declaratively and assert on
#  cycle_count / beat_count growth ; i499 archived 2026-05-08 enumerates
#  this shell as a Phase B target.]

set -u
set -m  # enable job control (process groups) for daemon isolation

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"

if [ -n "${HECKS_BIN:-}" ]; then
  HECKS="$HECKS_BIN"
elif [ -x "$REPO_ROOT/rust/target/release/storehouse" ]; then
  HECKS="$REPO_ROOT/rust/target/release/storehouse"
elif [ -x "/Users/christopheryoung/Projects/hecks/rust/target/release/storehouse" ]; then
  HECKS="/Users/christopheryoung/Projects/hecks/rust/target/release/storehouse"
else
  echo "FAIL — can't find storehouse binary"
  exit 2
fi

TMP=$(mktemp -d -t body_cycles_smoke.XXXXXX)
# Process-group cleanup : kill the entire group on EXIT so any daemon
# spawned during the test can't survive into the next test in a
# pre-commit gate batch. Combined with the tmpdir cleanup.
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/hecks_conception/information" "$TMP/hecks_conception/aggregates"
mkdir -p "$TMP/rust/target/release"
ln -sf "$HECKS" "$TMP/rust/target/release/storehouse"
find "$CONCEPT_DIR/aggregates" -name "*.bluebook" -exec ln -sf {} "$TMP/hecks_conception/aggregates/" \;
# Body cycles (Ultradian, SleepCycle, Pulse, etc.) live in the miette
# sibling repo at ../miette/body/. The test dispatches Ultradian.* and
# SleepCycle.* commands so those bluebooks must be reachable. Link from
# the sibling when present.
MIETTE_BODY="$REPO_ROOT/../miette/body"
if [ -d "$MIETTE_BODY" ]; then
  find "$MIETTE_BODY" -name "*.bluebook" -exec ln -sf {} "$TMP/hecks_conception/aggregates/" \;
fi

INFO="$TMP/hecks_conception/information"
AGG="$TMP/hecks_conception/aggregates"

# Force every storehouse invocation in this test to use our isolated
# information dir — keeps the smoke test from touching real Miette state.
export HECKS_INFO="$INFO"

fail() { echo "FAIL — $1"; "$HECKS" heki read "$STORE" 2>/dev/null | sed 's/^/    /'; exit 1; }

cd "$TMP/hecks_conception"

# ── 1. Ultradian fast-forward (i106 multi-command rotation) ──────
"$HECKS" loop "$AGG" Body::Ultradian.EnterPeak,Body::Ultradian.EnterTrough --every 1s >/dev/null 2>&1 &
PID=$!
sleep 2.5
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

STORE="$INFO/ultradian/ultradian.heki"
cycle_count=$("$HECKS" heki latest-field "$STORE" cycle_count 2>/dev/null || echo 0)
phase=$("$HECKS" heki latest-field "$STORE" phase 2>/dev/null || echo "")
[ "$cycle_count" -ge 1 ] || fail "ultradian: expected cycle_count ≥1, got $cycle_count"
echo "ultradian fast-forward (i106): cycle_count=$cycle_count, phase=$phase"

# ── 2. Heart.Beat gated cadence — open gate (i108) ───────────────
# The gated-cadence primitive (i108) is verified via Heart.Beat — a
# simple single-command primitive that increments beat_count. Original
# smoke used SleepCycle.EnterNREM* commands which were retired by the
# dream-study refactor (SleepCycle is now a process_manager driven by
# Body.Advance* events, not a cadence target). Heart.Beat covers the
# i108 contract cleanly without depending on retired commands.
mkdir -p "$INFO/consciousness"
"$HECKS" heki upsert "$INFO/consciousness/consciousness.heki" \
  --reason "test setup : set consciousness asleep so the gated-cadence test opens" \
  id=1 state=sleeping >/dev/null 2>&1

"$HECKS" loop "$AGG" Body::Heart.Beat \
  --every 500ms --gate "$INFO/consciousness/consciousness.heki:state=sleeping" >/dev/null 2>&1 &
PID=$!
sleep 2
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

STORE="$INFO/heart/heart.heki"
heart_count=$("$HECKS" heki latest-field "$STORE" beat_count 2>/dev/null || echo 0)
[ "$heart_count" -ge 1 ] || fail "heart: expected beat_count ≥1 while sleeping, got $heart_count"
echo "heart gated fast-forward (i108 gate=open): beat_count=$heart_count"

# Capture the count after the sleeping phase ; it must NOT advance once
# the gate is closed (state=attentive).
gated_baseline="$heart_count"

# ── 3. Heart.Beat awake gate — no dispatches fire (i108 gate=closed) ─
"$HECKS" heki upsert "$INFO/consciousness/consciousness.heki" \
  --reason "test setup : set consciousness attentive so the gate closes for the awake-gate proof" \
  id=1 state=attentive >/dev/null 2>&1

"$HECKS" loop "$AGG" Body::Heart.Beat \
  --every 500ms --gate "$INFO/consciousness/consciousness.heki:state=sleeping" >/dev/null 2>&1 &
PID=$!
sleep 2
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

after_gate=$("$HECKS" heki latest-field "$STORE" beat_count 2>/dev/null || echo 0)
[ "$after_gate" = "$gated_baseline" ] \
  || fail "heart: gate did not close — beat_count $gated_baseline → $after_gate"
echo "heart awake gate (i108 gate=closed): beat_count held at $after_gate"

echo "PASS — i106 multi-command rotation + i108 gated cadence both work"
exit 0
