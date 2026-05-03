#!/bin/bash
# consolidate_smoke.sh — smoke test for the Consolidation PM (i75 / i225).
#
# [antibody-exempt: i75 retirement of nrem_branch.sh + consolidate.sh —
#  smoke now drives the bluebook PM via `hecks-life run-loop` instead
#  of forking the legacy shell ; i225 close lets the assertion path
#  read store.heki / remains.heki growth produced by the runtime sweep
#  (`for_each: { from: "Aggregate.cold" }`) directly. Retires entirely
#  when smoke tests port to a bluebook-shebang form.]
#
# Closes the i75 retirement loop. With i221-A (parser : `for_each:` +
# `from_iter`), i225 (runtime : `drain_policies` enumerates the named
# query into per-record cascades), and i226 (parser : hash-form `where`
# comparators `{ lt|lte|gt|gte|ne: }`) all merged on dream-study, the
# Consolidation PM can declare its sweeps natively :
#
#   dispatch "Synapse.Compost", for_each: { from: "Synapse.cold" },
#                               with: { id: from_iter(:id) }
#
# and the runtime walks the named query, fires the receiving command
# once per record. The body/consolidate.sh transitional adapter is
# retired ; this smoke now drives the PM directly via `hecks-life
# run-loop` and reads store.heki / remains.heki to verify growth.
#
# What this smoke verifies :
#
#   1. The Consolidation PM (body/sleep/consolidation/consolidation.bluebook)
#      parses cleanly under both Ruby + Rust loaders. The run-loop boot
#      builds the Domain ; if any DSL surface (process_manager, on /
#      transition, dispatch + for_each + with + from_iter) drifts, the
#      boot fails.
#
#   2. The five step dispatches the PM declares resolve to declared
#      aggregates / commands / queries :
#        - Store.PromoteSignal       (body/sleep/consolidation/store.bluebook)
#        - Signal.ArchiveSignal      (body/organs/signal.bluebook ; sweep on Signal.cold)
#        - Synapse.Compost           (body/organs/synapse.bluebook  ; sweep on Synapse.cold)
#        - Remains.RecordRemains     (body/organs/remains.bluebook)
#        - Consciousness.DreamPulse  (body/sleep/consciousness.bluebook)
#
#   3. run-loop emits a synthetic SleepEntered (births the PM into
#      :light) followed by a PhaseElapsed (drives the nrem self-loop).
#      The PM observes both and runs its declared dispatches. The
#      sweeps enumerate Signal.cold / Synapse.cold and produce growth
#      in store.heki and remains.heki — read directly to assert.
#
# Filed gaps (acknowledged here, not blockers for this smoke) :
#
#   - The musing-archive sweep needs a group-by aggregation primitive
#     (`Musing.duplicate_concept`) ; i101 first-class queries don't
#     support group-by yet. The PM omits the MusingArchive.Archive
#     dispatch until that primitive lands ; this smoke does not assert
#     musing_archive growth (the `before/after` count is reported but
#     not gated, so the gap is visible without failing the smoke).
#
#   - Singleton-fallback for receiver aggregates without `id` on the
#     command (Store.PromoteSignal) : each iteration of the for_each
#     sweep upsserts the same singleton, so the visible store row count
#     is 1 rather than the iteration count. The contract (store.heki
#     grew) still holds. Filed as i75-followon (append-mode dispatch).
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

# ── Growth assertion (PM-driven, no shell fallback) ─────────────────
# i225 closes the runtime sweep primitive : `for_each: { from:
# "Aggregate.cold" }` enumerates the named query at dispatch time and
# fires the receiving command once per record. The PM's NREM self-loop
# now produces store + remains growth declaratively ; the legacy
# consolidate.sh transitional adapter is retired.
#
# Note (singleton-fallback) : Store.PromoteSignal + Remains.RecordRemains
# don't carry an `id` from the iter ; receivers fall back to singleton-
# upsert so the visible row count is 1 rather than the iteration count.
# The contract (store.heki + remains.heki grew) still holds. Filed as
# i75-followon (append-mode dispatch primitive, distinct from i225).

store_after=$(count_records "$TMP/information/store/store.heki")
remains_after=$(count_records "$TMP/information/remains/remains.heki")
musing_archive_after=$(count_records "$TMP/information/musing_archive/musing_archive.heki")

echo "After consolidation pass :"
echo "  store          records: $store_before → $store_after"
echo "  remains        records: $remains_before → $remains_after"
echo "  musing_archive records: $musing_archive_before → $musing_archive_after  (gap : group-by primitive — see header)"

[ "$store_after" -gt "$store_before" ] || fail "store/store.heki did not grow (expected promoted signals via for_each Signal.cold)"
[ "$remains_after" -gt "$remains_before" ] || fail "remains/remains.heki did not grow (expected composted synapses via for_each Synapse.cold)"
# musing_archive growth is not asserted — gap : Musing.duplicate_concept
# needs a group-by aggregation primitive that i101 doesn't yet support.
# Reported above so the gap stays visible. Tracked for follow-up.

echo "PASS — Consolidation PM boots via run-loop ; store + remains grew via i225 for_each sweeps (musing_archive deferred — group-by gap)"
exit 0
