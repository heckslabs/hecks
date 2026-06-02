#!/bin/bash
# body_cycles_smoke.sh — bus-routed smoke for the body-cycle cadence primitives.
#
# Restores the coverage deleted in PR #717 (sprint-14
# make-heki-direct-write-impossible). The original drove `storehouse loop`
# and seeded the Consciousness gate via raw `heki upsert`. The bus is
# now the only writer, so seeding flows through bus dispatch instead :
#
#   - Mind::Consciousness.EnterDaydream + .EnterSleep (one-shot dispatch)
#     replace the raw upsert that pinned consciousness.state=sleeping.
#   - `storehouse loop` is unchanged — it dispatches the loop command
#     through the runtime, never through raw heki writes.
#
# Verifies :
#   1. i106 multi-command rotation — `storehouse loop A,B --every 1s` :
#      Body::Ultradian.EnterPeak,EnterTrough rotates phase peak ↔ trough
#      and cycle_count advances in ~2.5s of live cadence.
#   2. i108 gated cadence — `storehouse loop X --every 500ms --gate ...` :
#      Body::Heart.Beat ticks while consciousness.state=sleeping (gate open),
#      holds while consciousness.state=attentive (gate closed).
#
# Exit 0 on pass, non-zero on fail.

set -u
set -m

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"

GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"
case "$GIT_COMMON" in
  /*) MAIN_REPO="$(cd "$(dirname "$GIT_COMMON")" && pwd)" ;;
  ?*) MAIN_REPO="$(cd "$REPO_ROOT/$(dirname "$GIT_COMMON")" && pwd)" ;;
  *)  MAIN_REPO="$REPO_ROOT" ;;
esac

if [ -n "${HECKS_BIN:-}" ]; then
  HECKS="$HECKS_BIN"
elif [ -x "$REPO_ROOT/rust/target/release/storehouse" ]; then
  HECKS="$REPO_ROOT/rust/target/release/storehouse"
elif [ -x "$MAIN_REPO/rust/target/release/storehouse" ]; then
  HECKS="$MAIN_REPO/rust/target/release/storehouse"
else
  echo "FAIL — can't find storehouse binary"
  exit 2
fi

TMP=$(mktemp -d -t body_cycles_smoke.XXXXXX)
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/hecks_conception/information" "$TMP/hecks_conception/aggregates"
find "$CONCEPT_DIR/aggregates" -name "*.bluebook" -exec ln -sf {} "$TMP/hecks_conception/aggregates/" \;

MIETTE_BODY="$MAIN_REPO/../miette/body"
if [ -d "$MIETTE_BODY" ]; then
  find "$MIETTE_BODY" -name "*.bluebook" -exec ln -sf {} "$TMP/hecks_conception/aggregates/" \;
fi

INFO="$TMP/hecks_conception/information"
AGG="$TMP/hecks_conception/aggregates"

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
#
# Seed consciousness=sleeping via BUS dispatch (i717 retirement of raw
# heki writes). EnterDaydream then EnterSleep lands the state on "sleeping"
# through the lifecycle gate the bluebook declares.
"$HECKS" "$AGG" Mind::Consciousness.EnterDaydream >/dev/null 2>&1 \
  || fail "EnterDaydream dispatch failed"
"$HECKS" "$AGG" Mind::Consciousness.EnterSleep >/dev/null 2>&1 \
  || fail "EnterSleep dispatch failed"

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

gated_baseline="$heart_count"

# ── 3. Heart.Beat awake gate — no dispatches fire (i108 gate=closed) ─
# WakeUp cascades through WitnessWake / SelfModel / StatusOnSelfModel
# policies, landing consciousness.state="attentive" via BecomeAttentive
# without a second explicit dispatch (which the lifecycle gate now
# refuses once state has already advanced past waking).
"$HECKS" "$AGG" Mind::Consciousness.WakeUp >/dev/null 2>&1 \
  || fail "WakeUp dispatch failed"

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
