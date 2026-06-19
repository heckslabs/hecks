#!/bin/bash
# pulse_organs_smoke.sh — smoke test for the Pulse process_manager that
# replaced body/pulse_organs.sh in i75.
#
# The retirement moves from imperative shell (per-tick fork storehouse
# N times) to declarative bluebook : a Pulse PM observes BodyPulse
# events and fans out the four organ-step dispatches (Synapse / Signal
# / Focus / Remains). The runtime walks the bluebook, no shell.
#
# This test boots `storehouse run-loop` against an isolated tmpdir,
# emitting BodyPulse:Pulse:pulse at 1s cadence for ~10 ticks. The PM
# (declared in body/pulse_organs/pulse_organs.bluebook) reacts to each
# BodyPulse and dispatches into Synapse / Signal / Focus / Remains.
# Acceptance : every organ heki file has at least one record after
# the loop runs.
#
# Compared to the old shell harness :
#   - No `bash $BODY_DIR/pulse_organs.sh` — the shell is deleted.
#   - One persistent process instead of 10 forks (run-loop is the
#     daemon, the dispatches happen in-process).
#   - The signal heki populates with one record (singleton-upsert
#     today) rather than the old append-style 20 ; per-record fan-out
#     elevates this back when the runtime gap is filled (filed in
#     body/pulse_organs/pulse_organs.bluebook header).
#
# Exit 0 on pass, non-zero on fail.
#
# [antibody-exempt: smoke-test shell harness for the Pulse PM that
#  retired pulse_organs.sh. Drives `storehouse run-loop` and proves
#  the four organ heki stores populate via the bluebook path. Retires
#  under i499 Phase B once the `.behaviors` runner can dispatch the
#  --emit BodyPulse fan-out and assert on per-organ heki growth ; the
#  i499 inbox (archived 2026-05-08) names this shell as a Phase B
#  target. Phase A (runner) is the keystone gap.]

set -u
set -m  # enable job control (process groups) for daemon isolation

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"

# i565 — worktree-aware MAIN_REPO anchor. From a .claude/worktrees/*
# checkout, REPO_ROOT/../miette doesn't exist (worktrees have no
# sibling miette repo and no rust/target/). Resolve the canonical
# main checkout via git-common-dir so both the sibling-body link
# and the storehouse binary find their canonical location. Same
# pattern as i561's landed fix on pulse_fanout_smoke.
GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"
case "$GIT_COMMON" in
  /*) MAIN_REPO="$(cd "$(dirname "$GIT_COMMON")" && pwd)" ;;
  ?*) MAIN_REPO="$(cd "$REPO_ROOT/$(dirname "$GIT_COMMON")" && pwd)" ;;
  *)  MAIN_REPO="$REPO_ROOT" ;;
esac

# i117 Round 4 — body bluebooks live in ~/Projects/miette/body/.
# i565 — try MAIN_REPO/../miette before falling back to CONCEPT_DIR.
BODY_DIR="${HECKS_BODY_DIR:-}"
[ -z "$BODY_DIR" ] && [ -d "$REPO_ROOT/../miette/body" ] && \
  BODY_DIR="$(cd "$REPO_ROOT/../miette/body" && pwd)"
[ -z "$BODY_DIR" ] && [ -d "$MAIN_REPO/../miette/body" ] && \
  BODY_DIR="$(cd "$MAIN_REPO/../miette/body" && pwd)"
[ -z "$BODY_DIR" ] && BODY_DIR="$CONCEPT_DIR"

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

TMP=$(mktemp -d -t pulse_organs_smoke.XXXXXX)
# Process-group cleanup : kill the entire group on EXIT so the
# run-loop daemon can't survive into the next test.
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$TMP"' EXIT

# Bluebook tree the run-loop will load. The Pulse PM lives in
# pulse_organs/pulse_organs.bluebook ; the four organ aggregates live
# in body/organs/{synapse,signal,focus,remains}.bluebook. We link the
# whole body/ tree so the runtime sees both the PM and its dispatch
# targets.
mkdir -p "$TMP/bluebooks/pulse_organs" "$TMP/bluebooks/organs"
ln -sf "$BODY_DIR/pulse_organs/pulse_organs.bluebook" \
       "$TMP/bluebooks/pulse_organs/pulse_organs.bluebook"
ln -sf "$BODY_DIR/pulse_organs/pulse_organs.hecksagon" \
       "$TMP/bluebooks/pulse_organs/pulse_organs.hecksagon"
for agg in synapse signal focus remains; do
  ln -sf "$BODY_DIR/organs/${agg}.bluebook" \
         "$TMP/bluebooks/organs/${agg}.bluebook"
done

# *.world pins the heki dir so the runtime persists into our tmpdir.
mkdir -p "$TMP/information"
cat > "$TMP/bluebooks/pulse_organs_smoke.world" <<EOF
Hecks.world "PulseOrgansSmoke" do
  # dir :default keys the store by THIS conception's directory. The tmpdir is
  # not under ~/Projects, so :default co-locates the store at <tmpdir>/.heki —
  # automatically isolated from the live ~/.heki, no HECKS_INFO, no literal path.
  heki do
    dir :default
  end
end
EOF

fail() { echo "FAIL — $1"; exit 1; }

# Run the loop driver for ~10 ticks. --every 1s + 10.5s sleep gives
# the PM ten BodyPulse self-loops to fan out into the organ stores.
# Persistence is configured by the *.world's `dir :default` above (keyed by
# this tmpdir) — no HECKS_INFO ; the world is the single store authority.
"$HECKS" run-loop "$TMP/bluebooks" \
  --every 1s \
  --emit BodyPulse:Pulse:pulse \
  >"$TMP/run-loop.log" 2>&1 &
PID=$!
sleep 10.5
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

count_records() {
  [ ! -f "$1" ] && { echo 0; return; }
  "$HECKS" heki count "$1" 2>/dev/null || echo 0
}

# The runtime persists per-aggregate stores under <data_dir>/<aggregate>/.
# find_world_heki_dir resolves *.world's `heki { dir ... }` to set the
# data_dir ; our world points it at $TMP/information. The organ stores
# land at $TMP/information/<aggregate>/<aggregate>.heki.
# The :default world co-locates the store at <tmpdir>/.heki, keyed by the
# conception dir. Per-aggregate stores land at <store>/<aggregate>/<aggregate>.heki.
INFO="$TMP/bluebooks/.heki"
synapse_heki="$INFO/synapse/synapse.heki"
signal_heki="$INFO/signal/signal.heki"
focus_heki="$INFO/focus/focus.heki"
remains_heki="$INFO/remains/remains.heki"

synapse_count=$(count_records "$synapse_heki")
signal_count=$(count_records "$signal_heki")
focus_count=$(count_records "$focus_heki")
remains_count=$(count_records "$remains_heki")

echo "After ~10 BodyPulse ticks (run-loop, no shell):"
echo "  synapse records: $synapse_count   ($synapse_heki)"
echo "  signal records:  $signal_count    ($signal_heki)"
echo "  focus records:   $focus_count     ($focus_heki)"
echo "  remains records: $remains_count   ($remains_heki)"

# Acceptance : every organ heki has at least one record. The shell
# harness used >1 for signals (append-style) ; the PM today singleton-
# upserts so 1 is the floor — append-mode dispatch (filed runtime gap
# in pulse_organs.bluebook) elevates this when the primitive lands.
[ "$synapse_count" -ge 1 ] || fail "synapse heki has no records (run-loop log: $TMP/run-loop.log)"
[ "$signal_count"  -ge 1 ] || fail "signal heki has no records (run-loop log: $TMP/run-loop.log)"
[ "$focus_count"   -ge 1 ] || fail "focus heki has no records (run-loop log: $TMP/run-loop.log)"
[ "$remains_count" -ge 1 ] || fail "remains heki has no records (run-loop log: $TMP/run-loop.log)"

echo "PASS — Pulse PM grows synapse/signal/focus/remains via the bluebook path"
exit 0
