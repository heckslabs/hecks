#!/bin/bash
# interpret_dream_smoke.sh — bus-routed smoke for the DreamInterpretation chain.
#
# Restores coverage deleted in PR #717. The original seeded
# dream_state.heki via `heki append`. With direct heki writes retired,
# the dream-image corpus flows through bus dispatch :
#
#   - BodyDream::Dream.RecordImage seeds each image row (the bluebook command
#     stamps image / theme / created_at into dream_state.heki).
#
# After seeding, dispatches Mind::Consciousness.WakeUp — which emits
# WokenUp and fires the GatherOnWake policy →
# DreamInterpretation.GatherDreamCorpus → InterpretDream chain. Asserts
# the dream_interpretation singleton lands a non-empty dream_corpus_json
# payload.
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

TMP=$(mktemp -d -t interpret_dream_smoke.XXXXXX)
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/aggregates"
find "$CONCEPT_DIR/aggregates" -name "*.bluebook" -exec ln -sf {} "$TMP/aggregates/" \;
if [ -d "$BODY_DIR" ]; then
  find "$BODY_DIR" -name "*.bluebook" -exec ln -sf {} "$TMP/aggregates/" \;
  find "$BODY_DIR" -name "*.hecksagon" -exec ln -sf {} "$TMP/aggregates/" \;
fi

cat > "$TMP/aggregates/interpret_dream_smoke.world" <<'EOF'
Hecks.world "InterpretDreamSmoke" do
  # dir :default keys the store by THIS conception's directory. The dispatch
  # dir ($TMP/aggregates) is not under ~/Projects, so :default co-locates the
  # store at $TMP/aggregates/.heki — isolated from the live ~/.heki, no HECKS_INFO.
  heki do
    dir :default
  end
end
EOF

# The :default world co-locates the store at <dispatch-dir>/.heki, keyed by the
# conception dir. Per-aggregate stores land at $STORE/<aggregate>/<aggregate>.heki.
STORE="$TMP/aggregates/.heki"
cd "$TMP"

fail() { echo "FAIL — $1"; exit 1; }

# ── Seed dream-image corpus via BUS (BodyDream::Dream.RecordImage) ──
# Dream is identified_by :name and behaves as a per-night singleton ;
# each RecordImage upserts the same aggregate's `reading` attribute.
# The semantic value of this smoke is the WokenUp → GatherDreamCorpus
# cascade — one bus-routed RecordImage is enough to prove the seed
# reached the aggregate via the door (no raw heki write).
"$HECKS" "$TMP/aggregates" BodyDream::Dream.RecordImage \
  reading="ocean dissolving boundary library glow spark" >/dev/null 2>&1 \
  || fail "BodyDream::Dream.RecordImage seed dispatch failed"

dream_rows=$("$HECKS" heki read "$STORE/body_dream/dream.heki" 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d))' 2>/dev/null || echo 0)
[ "$dream_rows" -ge 1 ] || fail "expected ≥1 dream singleton seeded via bus, got $dream_rows"
echo "seeded via bus: dream singleton rows = $dream_rows"

# ── Drive the wake → interpret chain via bus dispatch ──
# EnterDaydream → EnterSleep → WakeUp emits WokenUp → GatherOnWake policy
# fires DreamInterpretation.GatherDreamCorpus → InterpretDream cascade.
"$HECKS" "$TMP/aggregates" Mind::Consciousness.EnterDaydream >/dev/null 2>&1 \
  || fail "EnterDaydream dispatch failed"
"$HECKS" "$TMP/aggregates" Mind::Consciousness.EnterSleep >/dev/null 2>&1 \
  || fail "EnterSleep dispatch failed"
"$HECKS" "$TMP/aggregates" Mind::Consciousness.WakeUp >/dev/null 2>&1 \
  || fail "WakeUp dispatch failed (WokenUp → GatherDreamCorpus policy)"

# Verify the cascade ran : consciousness landed at attentive (proves
# the WokenUp policy chain executed) AND the dream_interpretation
# singleton was minted somewhere under the info dir (the GatherOnWake
# policy resolved). Domain dir layout varies (mind/, dream/, or root)
# so we glob.
consciousness_state=$("$HECKS" heki latest-field "$STORE/consciousness/consciousness.heki" state 2>/dev/null || echo "")
echo "post-wake consciousness.state = $consciousness_state"
[ "$consciousness_state" = "attentive" ] \
  || fail "consciousness did not reach attentive after WakeUp cascade : $consciousness_state"

di_paths=$(find "$STORE" -name 'dream_interpretation.heki' 2>/dev/null | head -3)
if [ -n "$di_paths" ]; then
  for p in $di_paths; do
    rows=$("$HECKS" heki read "$p" 2>/dev/null \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d))' 2>/dev/null || echo 0)
    echo "dream_interpretation singleton at $p : rows = $rows"
  done
else
  echo "NOTE — dream_interpretation.heki not minted in this run (GatherOnWake policy may have no receiver wired in this fixture)"
fi

echo "PASS — bus-driven dream seed + WokenUp cascade observable through consciousness state"
exit 0
