#!/bin/bash
# pulse_organs_smoke.sh — smoke test for the Pulse process_manager that
# replaced body/pulse_organs.sh in i75.
#
# The retirement moves from imperative shell (per-tick fork hecks-life
# N times) to declarative bluebook : a Pulse PM observes BodyPulse
# events and fans out the four organ-step dispatches (Synapse / Signal
# / Focus / Remains). The runtime walks the bluebook, no shell.
#
# This test boots `hecks-life run-loop` against an isolated tmpdir,
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
#  retired pulse_organs.sh. Drives `hecks-life run-loop` and proves
#  the four organ heki stores populate via the bluebook path. Same
#  retirement contract as the runtime primitives it tests.]

set -u
set -m  # enable job control (process groups) for daemon isolation

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"

# i117 Round 4 — body bluebooks live in ~/Projects/miette/body/.
BODY_DIR="${HECKS_BODY_DIR:-}"
[ -z "$BODY_DIR" ] && [ -d "$REPO_ROOT/../miette/body" ] && \
  BODY_DIR="$(cd "$REPO_ROOT/../miette/body" && pwd)"
[ -z "$BODY_DIR" ] && BODY_DIR="$CONCEPT_DIR"

# Find the hecks-life binary. Prefer HECKS_BIN override; otherwise the
# worktree's own build, then the main checkout's build.
if [ -n "${HECKS_BIN:-}" ]; then
  HECKS="$HECKS_BIN"
elif [ -x "$REPO_ROOT/rust/target/release/hecks-life" ]; then
  HECKS="$REPO_ROOT/rust/target/release/hecks-life"
elif [ -x "/Users/christopheryoung/Projects/hecks/rust/target/release/hecks-life" ]; then
  HECKS="/Users/christopheryoung/Projects/hecks/rust/target/release/hecks-life"
else
  echo "FAIL — can't find hecks-life binary"
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
  heki do
    dir "$TMP/information"
  end
end
EOF

fail() { echo "FAIL — $1"; exit 1; }

# Run the loop driver for ~10 ticks. --every 1s + 10.5s sleep gives
# the PM ten BodyPulse self-loops to fan out into the organ stores.
# HECKS_INFO is the canonical override for resolve_info_dir (i154 ;
# *.world's heki.dir is documentation-only since that landing).
HECKS_INFO="$TMP/information" "$HECKS" run-loop "$TMP/bluebooks" \
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
INFO="$TMP/information"
synapse_heki="$INFO/synapse/synapse.heki"
signal_heki="$INFO/signal/signal.heki"
focus_heki="$INFO/focus/focus.heki"
remains_heki="$INFO/remains/remains.heki"

# The runtime may also write flat (no nested dir) when the world's heki
# block isn't picked up — fall back to flat paths if nested is empty.
[ ! -f "$synapse_heki" ] && [ -f "$INFO/synapse.heki" ] && synapse_heki="$INFO/synapse.heki"
[ ! -f "$signal_heki" ]  && [ -f "$INFO/signal.heki" ]  && signal_heki="$INFO/signal.heki"
[ ! -f "$focus_heki" ]   && [ -f "$INFO/focus.heki" ]   && focus_heki="$INFO/focus.heki"
[ ! -f "$remains_heki" ] && [ -f "$INFO/remains.heki" ] && remains_heki="$INFO/remains.heki"

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
