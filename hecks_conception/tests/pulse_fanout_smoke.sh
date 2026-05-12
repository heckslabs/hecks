#!/bin/bash
# [antibody-exempt: i37 Phase C — porting legacy python to shell +
#  storehouse subcommands; retires when shell ports to bluebook shebang
#  form.]
#
# pulse_fanout_smoke.sh — Stage-A shadow for the across "Pulse" fanout.
#
# Recovers the end-to-end coverage that the mindstream.behaviors test
# lost in PR #277 when it was narrowed to ["Ticked"] (the single-bluebook
# .behaviors runner can't follow across hops into pulse.bluebook).
#
# The runtime fanout still fires — this test proves it by dispatching a
# single Tick.MindstreamTick into a tmpdir-isolated runtime and
# asserting that events landed in at least one aggregate on each side
# of the BodyPulse bus:
#
#   - pulse.heki        → BodyPulse emitted (proves across "Pulse" hop)
#   - heartbeat.heki    → body-side  (FatigueOnPulse → AccumulateFatigue)
#   - signal_consolidation.heki → mindstream-side (PruneOnPulse → PruneSynapses)
#   - nerve.heki        → being-side (SenseOrgansOnHeartbeat → ConnectNerve)
#
# Regression proof: comment out `across "Pulse"` in mindstream.bluebook
# and re-run — pulse.heki stays empty and every downstream assertion
# fails.

set -u
set -m  # enable job control (process groups) for daemon isolation

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"

# i561 — worktree-aware anchor. When the test runs inside a
# .claude/worktrees/* checkout, `REPO_ROOT/../miette` doesn't exist
# (the worktree has no sibling miette repo, and no rust/target/).
# Resolve the MAIN checkout via git-common-dir so both the sibling-
# repo body link and the storehouse binary resolve to the same place
# regardless of which worktree fires the test.
GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"
case "$GIT_COMMON" in
  /*) MAIN_REPO="$(cd "$(dirname "$GIT_COMMON")" && pwd)" ;;
  ?*) MAIN_REPO="$(cd "$REPO_ROOT/$(dirname "$GIT_COMMON")" && pwd)" ;;
  *)  MAIN_REPO="$REPO_ROOT" ;;
esac

# Find the storehouse binary. Prefer HECKS_BIN override; otherwise the
# worktree's own build, then the main checkout's build.
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

TMP=$(mktemp -d -t pulse_fanout_smoke.XXXXXX)
# Process-group cleanup : kill the entire group on EXIT so any daemon
# spawned during the test can't survive into the next test.
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/information" "$TMP/aggregates"

# Link all aggregates so cross-bluebook dispatch resolves. The across
# "Pulse" hop in mindstream.bluebook only fires if pulse.bluebook is in
# the same aggregates directory at dispatch time.
# i112 anatomy — bluebooks live in cluster subdirs (body/, mind/, ...) ;
# the runtime walks recursively, so flatten via find.
find "$CONCEPT_DIR/aggregates" -name "*.bluebook" -exec ln -sf {} "$TMP/aggregates/" \;
# Body / mind / being aggregates live in the miette sibling repo (Heart,
# Nerve, SignalConsolidation, Pulse, etc.). Link them so cross-bluebook
# dispatch — the across "Pulse" hop in mindstream — resolves at boot.
# i561 — MAIN_REPO resolves the main checkout when running from a worktree.
MIETTE_BODY="$MAIN_REPO/../miette/body"
if [ -d "$MIETTE_BODY" ]; then
  find "$MIETTE_BODY" -name "*.bluebook" -exec ln -sf {} "$TMP/aggregates/" \;
fi

# *.world pins the heki dir — the runtime reads it relative to CWD.
cat > "$TMP/pulse_fanout_smoke.world" <<'EOF'
Hecks.world "PulseFanoutSmoke" do
  heki do
    dir "information"
  end
end
EOF

fail() { echo "FAIL — $1"; exit 1; }

# One Tick. Everything downstream rides on this.
# i577 v2 follow-up : use FQN form Body::Tick.MindstreamTick — the
# canonical dispatch entry point gates on `::`. Tick lives in
# /Users/christopheryoung/Projects/miette/body/cycles/tick.bluebook
# which declares category "body".
(cd "$TMP" && HECKS_INFO="$TMP/information" HECKS_AGG="$TMP/aggregates" \
  "$HECKS" "$TMP/aggregates" Body::Tick.MindstreamTick >/dev/null 2>&1) \
  || fail "Body::Tick.MindstreamTick dispatch failed"

# Helpers — read one field from a singleton heki store, empty on miss.
# `heki latest-field` exits 3 on missing field or missing file; swallow
# that to preserve the old Python helper's "empty on any error" contract.
field() {
  "$HECKS" heki latest-field "$1" "$2" 2>/dev/null || true
}

pulse_count=$(field "$TMP/information/pulse/pulse.heki" count)
pulses=$(field "$TMP/information/heartbeat/heartbeat.heki" pulses_since_sleep)
pruned=$(field "$TMP/information/signal_consolidation/signal_consolidation.heki" synapses_pruned)
nerve_active=$(field "$TMP/information/nerve/nerve.heki" active)

echo "After 1 tick:"
echo "  pulse.count:                          $pulse_count"
echo "  heartbeat.pulses_since_sleep:         $pulses"
echo "  signal_consolidation.synapses_pruned: $pruned"
echo "  nerve.active:                         $nerve_active"

# BodyPulse emitted — the across "Pulse" hop fired.
[ "${pulse_count:-0}" -ge 1 ] 2>/dev/null \
  || fail "pulse.heki count < 1 — across \"Pulse\" hop did not fire"

# Body-side: FatigueOnPulse → AccumulateFatigue.
[ "${pulses:-0}" -ge 1 ] 2>/dev/null \
  || fail "heartbeat.pulses_since_sleep < 1 — body FatigueOnPulse did not fire"

# Mindstream-side: PruneOnPulse → PruneSynapses.
[ "${pruned:-0}" -ge 1 ] 2>/dev/null \
  || fail "signal_consolidation.synapses_pruned < 1 — mindstream PruneOnPulse did not fire"

# Being-side: SenseOrgansOnHeartbeat → ConnectNerve (or any nerve record).
[ -n "$nerve_active" ] \
  || fail "nerve.heki empty — being-side BodyPulse policies did not fire"

echo "PASS — across \"Pulse\" fanout covers pulse + body + mindstream + being"
exit 0
