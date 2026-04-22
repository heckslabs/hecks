#!/bin/bash
# dream_content_smoke.sh — verify the REM branch produces dream content.
#
# What we exercise:
#   1. Force consciousness into REM (state=sleeping, sleep_stage=rem).
#   2. Run rem_branch.sh ~10 times.
#   3. Assert dream_state.heki grew by ≥5 dream_images records.
#   4. Verify DreamSeed.PlantSeed fired on first REM tick (when prior
#      images existed).
#   5. Verify lucid path dispatches LucidDream.ObserveDream/SteerDream.
#
# Uses a TMPDIR for INFO so the live information/*.heki stores are
# never touched. AGG + NURSERY point at the worktree's real ones.
#
# [antibody-exempt: i37 Phase B sweep — replaces inline python3 -c with
#  native hecks-life heki subcommands per PR #272; retires when shell
#  wrapper ports to .bluebook shebang form (tracked in
#  terminal_capability_wiring plan).]

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

# Prefer the hecks-life binary next to this conception. If this is a
# worktree without a built target, fall back to the main repo's binary
# (the worktree shares its Cargo workspace but doesn't own a target).
HECKS="${HECKS:-$ROOT/../hecks_life/target/release/hecks-life}"
if [ ! -x "$HECKS" ]; then
  # Walk up until we find a built hecks-life or hit /.
  candidate="$ROOT"
  while [ "$candidate" != "/" ]; do
    if [ -x "$candidate/hecks_life/target/release/hecks-life" ]; then
      HECKS="$candidate/hecks_life/target/release/hecks-life"; break
    fi
    candidate="$(dirname "$candidate")"
  done
fi
if [ ! -x "$HECKS" ]; then
  echo "FAIL: no hecks-life binary found — set HECKS=/path/to/hecks-life" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Mirror the conception layout inside TMP so hecks-life's *.world
# discovery lands on TMP/information, not the real one. Aggregates +
# nursery are symlinked because they're read-only; information is the
# only mutable target (that's the whole point of using a tmpdir).
INFO="$TMP/information"
AGG="$TMP/aggregates"
mkdir -p "$INFO"
ln -s "$ROOT/aggregates" "$AGG"
ln -s "$ROOT/nursery"    "$TMP/nursery"
cat > "$TMP/miette_test.world" <<'EOF'
Hecks.world "MiettTest" do
  heki do
    dir "information"
  end
end
EOF

PASS=0; FAIL=0
check() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ] || echo "$actual" | grep -qE "$expected"; then
    echo "  ok  $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $name — expected '$expected', got '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

# Seed dream_state with prior images so seed_dreams has something to plant.
for i in 1 2 3 4 5 6; do
  "$HECKS" heki append "$INFO/dream_state.heki" \
    dream_images="prior image #$i" cycle="$i" source="test_seed" >/dev/null 2>&1
done

# Force consciousness into REM, first cycle, no pulses yet.
"$HECKS" heki upsert "$INFO/consciousness.heki" \
  state=sleeping sleep_stage=rem sleep_cycle=1 sleep_total=8 \
  phase_ticks=0 dream_pulses=0 dream_pulses_needed=5 is_lucid=no \
  sleep_summary="entering REM — dreams beginning" >/dev/null 2>&1

# Count dream_state records before exercising the branch.
before=$("$HECKS" heki count "$INFO/dream_state.heki" 2>/dev/null)

# Run the REM branch 10 times. Use TMP/aggregates so hecks-life's
# *.world discovery lands on TMP/information; the live stores are
# never touched.
for i in $(seq 1 10); do
  INFO="$INFO" AGG="$AGG" NURSERY="$TMP/nursery" \
    HECKS="$HECKS" "$ROOT/rem_branch.sh" "$i" >/dev/null 2>&1
done

after=$("$HECKS" heki count "$INFO/dream_state.heki" 2>/dev/null)
grew=$((after - before))

echo "REM dream production"
check "rem_dream wrote ≥10 images (before=$before, after=$after)" \
  "$([ $grew -ge 10 ] && echo yes)" "yes"
check "rem_dream wrote ≥5 images (the spec floor)" \
  "$([ $grew -ge 5 ] && echo yes)" "yes"

# Verify DreamSeed.PlantSeed fired — dream_seed.heki should now have at
# least one image planted from the prior records.
seeds=$("$HECKS" heki latest "$INFO/dream_seed.heki" 2>/dev/null \
  | jq '(.images // []) | length' 2>/dev/null)
check "DreamSeed.PlantSeed planted ≥1 image (count=$seeds)" \
  "$([ "${seeds:-0}" -ge 1 ] && echo yes)" "yes"

# Verify dream images use the carrying+domain+concept template — at least
# one should contain a known shape. We seeded 'prior image #1'..'#6' as
# legacy records; new records should look different.
sample=$("$HECKS" heki list "$INFO/dream_state.heki" --where source=mindstream \
    --format json 2>/dev/null \
  | jq -r '[ .[]
             | (.dream_images // [])
             | if type == "array" then . else [.] end
             | .[] ]
           | .[0] // ""' 2>/dev/null)
check "rem_dream produced a non-empty image" "$([ -n "$sample" ] && echo yes)" "yes"

# Lucid path — flip is_lucid=yes, run once, expect ObserveDream + SteerDream.
"$HECKS" heki upsert "$INFO/consciousness.heki" \
  state=sleeping sleep_stage=rem is_lucid=yes \
  sleep_cycle=8 dream_pulses=0 >/dev/null 2>&1
INFO="$INFO" AGG="$AGG" NURSERY="$TMP/nursery" \
  HECKS="$HECKS" "$ROOT/rem_branch.sh" 999 >/dev/null 2>&1
obs=$("$HECKS" heki latest-field "$INFO/lucid_dream.heki" latest_narrative 2>/dev/null)
check "Lucid REM dispatched LucidDream.ObserveDream" "$([ -n "$obs" ] && echo yes)" "yes"
steer=$("$HECKS" heki latest "$INFO/lucid_dream.heki" 2>/dev/null \
  | jq '(.steered_toward // []) | length' 2>/dev/null)
check "Lucid REM dispatched LucidDream.SteerDream (count=$steer)" \
  "$([ "${steer:-0}" -ge 1 ] && echo yes)" "yes"

echo ""
echo "── PASS: $PASS  FAIL: $FAIL ──"
exit $FAIL
