#!/bin/bash
# consolidate_smoke.sh — smoke test for consolidate.sh.
# [antibody-exempt: i37 Phase B sweep — replaces inline python3 -c with
#  native hecks-life heki subcommands + date -d for timestamp shifts per
#  PR #272; retires when shell wrapper ports to .bluebook shebang form
#  (tracked in terminal_capability_wiring plan).]
#
# Seeds a tmpdir with:
#   - 5 cold signals (access_count=0, created_at 120s ago) → should promote
#   - 2 fresh signals (created_at now)                     → should NOT promote
#   - 2 weak synapses (strength=0.05, alive)               → should compost
#   - 5 musings tagged with the same thinking_source      → 1 should archive
#     (>3 live on same concept → oldest moves to archive)
#
# Then runs consolidate.sh once and asserts:
#   - store.heki grew (memory entries were created)
#   - remains.heki grew (synapses were composted)
#   - musing_archive.heki grew (at least one musing archived)
#
# Exit 0 on pass, non-zero on fail.

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

TMP=$(mktemp -d -t consolidate_smoke.XXXXXX)
trap "rm -rf $TMP" EXIT

mkdir -p "$TMP/information" "$TMP/aggregates"

ln -sf "$CONCEPT_DIR/aggregates/"*.bluebook "$TMP/aggregates/"

cat > "$TMP/consolidate_smoke.world" <<'EOF'
Hecks.world "ConsolidateSmoke" do
  heki do
    dir "information"
  end
end
EOF

# ── Seed signals ─────────────────────────────────────────────────────
# iso_offset secs — print an ISO-8601 UTC timestamp `secs` seconds in
# the past. Portable across macOS (BSD date) and Linux (GNU date).
iso_offset() {
  local secs="$1" now_epoch
  now_epoch=$(date -u +%s)
  # awk formats the resulting epoch back into the expected ISO string.
  date -u -r "$((now_epoch - secs))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$((now_epoch - secs))" +%Y-%m-%dT%H:%M:%SZ
}

OLD=$(iso_offset 120)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for i in 1 2 3 4 5; do
  "$HECKS" heki append "$TMP/information/signal.heki" \
    kind=concept payload="cold_$i" strength=0.5 access_count=0 \
    created_at="$OLD" >/dev/null 2>&1
done
for i in 1 2; do
  "$HECKS" heki append "$TMP/information/signal.heki" \
    kind=concept payload="fresh_$i" strength=0.5 access_count=0 \
    created_at="$NOW" >/dev/null 2>&1
done

# ── Seed weak synapses ───────────────────────────────────────────────
for t in doomed_a doomed_b; do
  "$HECKS" heki append "$TMP/information/synapse.heki" \
    from="$t" to="$t" strength=0.05 state=alive firings=0 \
    last_fired_at="$OLD" >/dev/null 2>&1
done

# ── Seed musings: 5 share a concept ──────────────────────────────────
for i in 1 2 3 4 5; do
  ts=$(iso_offset $((i * 60)))
  "$HECKS" heki append "$TMP/information/musing.heki" \
    idea="musing number $i" source=mindstream thinking_source=wandering \
    conceived=false status=imagined created_at="$ts" >/dev/null 2>&1
done

fail() { echo "FAIL — $1"; exit 1; }

count_records() {
  [ ! -f "$1" ] && { echo 0; return; }
  "$HECKS" heki count "$1" 2>/dev/null || echo 0
}

store_before=$(count_records "$TMP/information/store.heki")
remains_before=$(count_records "$TMP/information/remains.heki")
musing_archive_before=$(count_records "$TMP/information/musing_archive.heki")

HECKS_INFO="$TMP/information" \
HECKS_AGG="$TMP/aggregates" \
HECKS_BIN="$HECKS" \
bash "$CONCEPT_DIR/consolidate.sh" \
  || fail "consolidate.sh exited non-zero"

store_after=$(count_records "$TMP/information/store.heki")
remains_after=$(count_records "$TMP/information/remains.heki")
musing_archive_after=$(count_records "$TMP/information/musing_archive.heki")

echo "After consolidate:"
echo "  store          records: $store_before → $store_after"
echo "  remains        records: $remains_before → $remains_after"
echo "  musing_archive records: $musing_archive_before → $musing_archive_after"

[ "$store_after" -gt "$store_before" ] || fail "store.heki did not grow (expected promoted signals)"
[ "$remains_after" -gt "$remains_before" ] || fail "remains.heki did not grow (expected composted synapses)"
[ "$musing_archive_after" -gt "$musing_archive_before" ] || fail "musing_archive.heki did not grow (expected archived musings)"

echo "PASS — consolidate.sh promotes signals, composts synapses, archives duplicate-concept musings"
exit 0
