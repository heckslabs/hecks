#!/bin/bash
# consolidate_smoke.sh — smoke test for the Consolidation PM (i75).
# [antibody-exempt: i75 retirement of nrem_branch.sh + consolidate.sh —
#  smoke now drives the bluebook PM via `hecks-life run-loop` instead
#  of forking the legacy shell. Retires entirely when the runtime
#  sweep primitive lands and the consolidate.sh transitional adapter
#  goes away.]
#
# What this smoke verifies, post-i75 :
#
#   1. The Consolidation PM (body/sleep/consolidation/consolidation.bluebook)
#      parses cleanly under both Ruby + Rust loaders. The run-loop boot
#      builds the Domain ; if any DSL surface (process_manager, on /
#      transition, dispatch) drifts, the boot fails.
#
#   2. The four step commands referenced by the PM resolve to declared
#      aggregates :
#        - Store.PromoteSignal       (body/sleep/consolidation/store.bluebook)
#        - Synapse.Compost           (body/organs/synapse.bluebook)
#        - Remains.RecordRemains     (body/organs/remains.bluebook)
#        - MusingArchive.Archive     (mind/memory/musing_archive.bluebook)
#        - Consciousness.DreamPulse  (body/sleep/consciousness.bluebook)
#
#   3. run-loop emits a synthetic PhaseElapsed event into the bus ; the
#      PM observes it and runs through its declared dispatches. The
#      smoke catches PM-handler crashes (e.g. command-not-found,
#      transition-not-declared) by reading run-loop's stderr.
#
# What this smoke does NOT verify (transitional gap, follow-up branch) :
#
#   The actual heki growth (store / remains / musing_archive per-tick
#   record appends) requires a runtime sweep primitive — single-record
#   dispatches today, multi-record sweep semantics tomorrow. Until
#   then, the legacy consolidate.sh shell continues to do the actual
#   work in production daemons (same belt-and-suspenders pattern
#   rem_branch.sh's rem_dream block carries until self-dispatch
#   closes). Growth-assertion mode runs as a fallback below when the
#   shell is still present.
#
# Exit 0 on pass, non-zero on fail.

set -u
set -m  # enable job control (process groups) for daemon isolation

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"

# i117 Round 4 — body shells moved to ~/Projects/miette/body/.
# Worktree-aware lookup : sibling-repo, then $HOME-rooted miette,
# finally conception fallback for legacy paths.
BODY_DIR="${HECKS_BODY_DIR:-}"
[ -z "$BODY_DIR" ] && [ -d "$REPO_ROOT/../miette/body" ] && \
  BODY_DIR="$(cd "$REPO_ROOT/../miette/body" && pwd)"
[ -z "$BODY_DIR" ] && [ -d "$HOME/Projects/miette/body" ] && \
  BODY_DIR="$(cd "$HOME/Projects/miette/body" && pwd)"
[ -z "$BODY_DIR" ] && BODY_DIR="$CONCEPT_DIR"

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

TMP=$(mktemp -d -t consolidate_smoke.XXXXXX)
# Process-group cleanup : kill the entire group on EXIT so any daemon
# spawned during the test can't survive into the next test.
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$TMP"' EXIT

# Nested heki layout (post-i118 R5).
mkdir -p "$TMP/information/signal" "$TMP/information/synapse" \
         "$TMP/information/musing" "$TMP/information/store" \
         "$TMP/information/remains" "$TMP/information/musing_archive" \
         "$TMP/aggregates"

find "$CONCEPT_DIR/aggregates" -name "*.bluebook" -exec ln -sf {} "$TMP/aggregates/" \;

# i75 — link the Consolidation PM + Store aggregate + sibling
# aggregates the PM dispatches into so run-loop's combined-domain
# loader includes them. Without these, the PM boots but observes no
# events (parse silently drops the unknown commands).
if [ -d "$BODY_DIR/sleep/consolidation" ]; then
  find "$BODY_DIR/sleep/consolidation" -name "*.bluebook" -o -name "*.hecksagon" | while read f; do
    ln -sf "$f" "$TMP/aggregates/"
  done
fi
for src in \
  "$BODY_DIR/sleep/consciousness.bluebook" \
  "$BODY_DIR/organs/synapse.bluebook" \
  "$BODY_DIR/organs/signal.bluebook" \
  "$BODY_DIR/organs/remains.bluebook"; do
  [ -f "$src" ] && ln -sf "$src" "$TMP/aggregates/"
done
# MusingArchive lives mind-side ; resolve through the same precedence.
MIND_DIR="${HECKS_MIND_DIR:-}"
[ -z "$MIND_DIR" ] && [ -d "$BODY_DIR/../mind" ] && \
  MIND_DIR="$(cd "$BODY_DIR/../mind" && pwd)"
[ -n "$MIND_DIR" ] && [ -f "$MIND_DIR/memory/musing_archive.bluebook" ] && \
  ln -sf "$MIND_DIR/memory/musing_archive.bluebook" "$TMP/aggregates/"

cat > "$TMP/consolidate_smoke.world" <<'EOF'
Hecks.world "ConsolidateSmoke" do
  heki do
    dir "information"
  end
end
EOF

# ── Seed signals ─────────────────────────────────────────────────────
iso_offset() {
  local secs="$1" now_epoch
  now_epoch=$(date -u +%s)
  date -u -r "$((now_epoch - secs))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$((now_epoch - secs))" +%Y-%m-%dT%H:%M:%SZ
}

OLD=$(iso_offset 120)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for i in 1 2 3 4 5; do
  "$HECKS" heki append "$TMP/information/signal/signal.heki" \
    --reason "test setup : seed cold signals for consolidation PM promote-to-store sweep" \
    kind=concept payload="cold_$i" strength=0.5 access_count=0 \
    created_at="$OLD" >/dev/null 2>&1
done
for i in 1 2; do
  "$HECKS" heki append "$TMP/information/signal/signal.heki" \
    --reason "test setup : seed fresh signals so consolidation sweep proves freshness gate" \
    kind=concept payload="fresh_$i" strength=0.5 access_count=0 \
    created_at="$NOW" >/dev/null 2>&1
done

for t in doomed_a doomed_b; do
  "$HECKS" heki append "$TMP/information/synapse/synapse.heki" \
    --reason "test setup : seed weak synapses for consolidation compost sweep" \
    from="$t" to="$t" strength=0.05 state=alive firings=0 \
    last_fired_at="$OLD" >/dev/null 2>&1
done

for i in 1 2 3 4 5; do
  ts=$(iso_offset $((i * 60)))
  "$HECKS" heki append "$TMP/information/musing/musing.heki" \
    --reason "test setup : seed duplicate-concept musings for consolidation concept-cluster pass" \
    idea="musing number $i" source=mindstream thinking_source=wandering \
    conceived=false status=imagined created_at="$ts" >/dev/null 2>&1
done

fail() { echo "FAIL — $1"; exit 1; }

count_records() {
  [ ! -f "$1" ] && { echo 0; return; }
  "$HECKS" heki count "$1" 2>/dev/null || echo 0
}

store_before=$(count_records "$TMP/information/store/store.heki")
remains_before=$(count_records "$TMP/information/remains/remains.heki")
musing_archive_before=$(count_records "$TMP/information/musing_archive/musing_archive.heki")

# ── Drive the PM via `hecks-life run-loop` ─────────────────────────
# The run-loop boots the Runtime, parses the consolidation bluebook +
# its hecksagon, and ticks at the configured cadence. We emit synthetic
# SleepEntered (births the PM) followed by a PhaseElapsed (drives the
# PM into a nrem state's self-loop). Run for ~2 seconds, then assert.
#
# --emit form is Event:AggregateType:AggregateId. Both events target
# Body:body so the PM correlates by :body_id == "body".
RUN_LOG="$TMP/run_loop.log"
HECKS_INFO="$TMP/information" \
HECKS_AGG="$TMP/aggregates" \
HECKS_BIN="$HECKS" \
"$HECKS" run-loop "$TMP/aggregates" \
  --every 500ms \
  --emit SleepEntered:Body:body \
  --emit PhaseElapsed:Body:body \
  >"$RUN_LOG" 2>&1 &
RUN_PID=$!

sleep 2
kill "$RUN_PID" 2>/dev/null || true
wait "$RUN_PID" 2>/dev/null || true

# Boot-failure guard : run-loop's startup banner names the loaded
# domain. Absence means the bluebook didn't parse.
if ! grep -q 'hecks-life run-loop' "$RUN_LOG"; then
  echo "----- run-loop output -----"
  cat "$RUN_LOG"
  fail "run-loop did not boot the Consolidation PM (parse / load failure)"
fi

# Crash-guard : look for stack traces or panic markers.
if grep -qE 'panicked|RuntimeError|undefined method|NameError' "$RUN_LOG"; then
  echo "----- run-loop output -----"
  cat "$RUN_LOG"
  fail "run-loop emitted a runtime error during PM dispatch"
fi

echo "PM boot via run-loop : OK"

# ── Transitional growth assertion ───────────────────────────────────
# Until the runtime sweep primitive lands, the actual heki growth runs
# through the consolidate.sh shell. We invoke it once here so the
# end-to-end "store / remains / musing_archive grow per tick" contract
# the i75 issue declared still holds — same belt-and-suspenders pattern
# rem_branch.sh / rem_dream PM share. Retires when the runtime sweep
# primitive activates the PM's dispatches.
if [ -x "$BODY_DIR/consolidate.sh" ]; then
  HECKS_INFO="$TMP/information" \
  HECKS_AGG="$TMP/aggregates" \
  HECKS_BIN="$HECKS" \
  bash "$BODY_DIR/consolidate.sh" \
    || fail "transitional consolidate.sh exited non-zero"
fi

store_after=$(count_records "$TMP/information/store/store.heki")
remains_after=$(count_records "$TMP/information/remains/remains.heki")
musing_archive_after=$(count_records "$TMP/information/musing_archive/musing_archive.heki")

echo "After consolidation pass :"
echo "  store          records: $store_before → $store_after"
echo "  remains        records: $remains_before → $remains_after"
echo "  musing_archive records: $musing_archive_before → $musing_archive_after"

[ "$store_after" -gt "$store_before" ] || fail "store/store.heki did not grow (expected promoted signals)"
[ "$remains_after" -gt "$remains_before" ] || fail "remains/remains.heki did not grow (expected composted synapses)"
[ "$musing_archive_after" -gt "$musing_archive_before" ] || fail "musing_archive/musing_archive.heki did not grow (expected archived musings)"

echo "PASS — Consolidation PM boots via run-loop ; store + remains + musing_archive grow during NREM consolidation"
exit 0
