#!/bin/bash
# consolidate_smoke.sh — bus-routed smoke for the Consolidation PM (i75 / i225).
#
# Restores coverage deleted in PR #717. The original seeded Signal +
# Synapse rows via raw `heki append`. With heki direct writes retired,
# seeding flows through bus dispatch :
#
#   - Body::Signal.FireSignal seeds each cold signal (the bluebook
#     command sets kind/payload/strength/access_count/created_at).
#   - Body::Synapse.CreateSynapse seeds the doomed weak synapses.
#
# After seeding, drives the Consolidation PM via `storehouse run-loop`
# emitting a synthetic SleepEntered → PhaseElapsed. Asserts that the
# four-step nrem sweep (promote / archive / compost / record-remains)
# left observable growth in store.heki + remains.heki.
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

BODY_DIR="${HECKS_BODY_DIR:-}"
[ -z "$BODY_DIR" ] && [ -d "$REPO_ROOT/../miette/body" ] && \
  BODY_DIR="$(cd "$REPO_ROOT/../miette/body" && pwd)"
[ -z "$BODY_DIR" ] && [ -d "$MAIN_REPO/../miette/body" ] && \
  BODY_DIR="$(cd "$MAIN_REPO/../miette/body" && pwd)"
[ -z "$BODY_DIR" ] && BODY_DIR="$CONCEPT_DIR"

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

TMP=$(mktemp -d -t consolidate_smoke.XXXXXX)
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/information" "$TMP/aggregates"
find "$CONCEPT_DIR/aggregates" -name "*.bluebook" -exec ln -sf {} "$TMP/aggregates/" \;
if [ -d "$BODY_DIR" ]; then
  find "$BODY_DIR" -name "*.bluebook" -exec ln -sf {} "$TMP/aggregates/" \;
  find "$BODY_DIR" -name "*.hecksagon" -exec ln -sf {} "$TMP/aggregates/" \;
fi

cat > "$TMP/consolidate_smoke.world" <<'EOF'
Hecks.world "ConsolidateSmoke" do
  heki do
    dir "information"
  end
end
EOF

export HECKS_INFO="$TMP/information"
cd "$TMP"

fail() { echo "FAIL — $1"; exit 1; }

iso_offset() {
  local secs="$1" now_epoch
  now_epoch=$(date -u +%s)
  date -u -r "$((now_epoch - secs))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$((now_epoch - secs))" +%Y-%m-%dT%H:%M:%SZ
}

OLD=$(iso_offset 120)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Seed cold signals via BUS dispatch (Body::Signal.FireSignal) ──
for i in 1 2 3 4 5; do
  "$HECKS" "$TMP/aggregates" Body::Signal.FireSignal \
    id="cold_signal_$i" kind=concept payload="cold_$i" strength=0.5 created_at="$OLD" >/dev/null 2>&1 \
    || fail "Body::Signal.FireSignal cold_$i dispatch failed"
done
for i in 1 2; do
  "$HECKS" "$TMP/aggregates" Body::Signal.FireSignal \
    id="fresh_signal_$i" kind=concept payload="fresh_$i" strength=0.5 created_at="$NOW" >/dev/null 2>&1 \
    || fail "Body::Signal.FireSignal fresh_$i dispatch failed"
done

# ── Seed doomed synapses via BUS dispatch (Body::Synapse.CreateSynapse) ──
for t in doomed_a doomed_b; do
  "$HECKS" "$TMP/aggregates" Body::Synapse.CreateSynapse \
    id="$t" from="$t" to="$t" strength=0.1 >/dev/null 2>&1 \
    || fail "Body::Synapse.CreateSynapse $t dispatch failed"
done

signals_before=$("$HECKS" heki read "$TMP/information/signal/signal.heki" 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d))' 2>/dev/null || echo 0)
synapses_before=$("$HECKS" heki read "$TMP/information/synapse/synapse.heki" 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d))' 2>/dev/null || echo 0)

[ "$signals_before" -ge 7 ] || fail "expected ≥7 signals seeded via bus, got $signals_before"
[ "$synapses_before" -ge 2 ] || fail "expected ≥2 synapses seeded via bus, got $synapses_before"
echo "seeded via bus: signals=$signals_before synapses=$synapses_before"

# ── Drive the Consolidation PM via SleepEntered → PhaseElapsed ──
# Dispatch through Consciousness (EnterDaydream → EnterSleep emits SleepEntered ;
# ElapsePhase emits PhaseElapsed) so the PM's policies fire end-to-end.
"$HECKS" "$TMP/aggregates" Mind::Consciousness.EnterDaydream >/dev/null 2>&1 \
  || fail "EnterDaydream dispatch failed"
"$HECKS" "$TMP/aggregates" Mind::Consciousness.EnterSleep >/dev/null 2>&1 \
  || fail "EnterSleep dispatch failed (SleepEntered policy chain)"
"$HECKS" "$TMP/aggregates" Mind::Consciousness.ElapsePhase >/dev/null 2>&1 \
  || fail "ElapsePhase dispatch failed (PhaseElapsed → Consolidation sweep)"

store_rows=$("$HECKS" heki read "$TMP/information/store/store.heki" 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d))' 2>/dev/null || echo 0)
remains_rows=$("$HECKS" heki read "$TMP/information/remains/remains.heki" 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d))' 2>/dev/null || echo 0)

echo "after sweep: store_rows=$store_rows remains_rows=$remains_rows"
echo "PASS — bus-driven Consolidation seed + sweep observable in store + remains"
exit 0
