#!/bin/bash
# interpret_dream_smoke.sh — smoke test for interpret_dream.sh.
#
# Seeds dream_state.heki with known images, runs interpret_dream.sh
# against a tmpdir, and asserts that interpretation.heki + musing.heki
# grew. Real information/*.heki is never touched — the test sandboxes
# against a tmp copy via HECKS_INFO / HECKS_AGG.
#
# Assertions:
#   - dream_interpretation.heki carries a non-empty interpretation
#   - dream_interpretation.heki carries a recurring_theme
#   - musing.heki has ≥1 record sourced from dreams
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

TMP=$(mktemp -d -t interpret_dream_smoke.XXXXXX)
trap "rm -rf $TMP" EXIT

mkdir -p "$TMP/information" "$TMP/aggregates"
ln -sf "$CONCEPT_DIR/aggregates/"*.bluebook "$TMP/aggregates/"

cat > "$TMP/world.hec" <<'EOF'
Hecks.world "InterpretDreamSmoke" do
  heki do
    dir "information"
  end
end
EOF

# Seed dream_state with images where "ocean" and "dissolving" recur ≥3x
# and "library" / "spark" appear once. Only "ocean" + "dissolving" should
# cross the ≥3 threshold and produce musings.
seed_image() {
  "$HECKS" heki append "$TMP/information/dream_state.heki" \
    source=test dream_images="$1" >/dev/null 2>&1
}
seed_image "the ocean dissolving in a library"
seed_image "ocean waves dissolving into spark"
seed_image "a ocean dissolving"
seed_image "library corridors"
seed_image "spark in the dark"

fail() { echo "FAIL — $1"; exit 1; }

HECKS_INFO="$TMP/information" \
HECKS_AGG="$TMP/aggregates" \
HECKS_BIN="$HECKS" \
HECKS_WORLD="$TMP" \
bash "$CONCEPT_DIR/interpret_dream.sh" \
  || fail "interpret_dream.sh exited non-zero"

count_records() {
  [ ! -f "$1" ] && { echo 0; return; }
  "$HECKS" heki read "$1" 2>/dev/null \
    | python3 -c "import json,sys
try: print(len(json.load(sys.stdin) or {}))
except Exception: print(0)" 2>/dev/null
}

interp_count=$(count_records "$TMP/information/dream_interpretation.heki")
musing_count=$(count_records "$TMP/information/musing_mint.heki")

interpretation=$("$HECKS" heki latest "$TMP/information/dream_interpretation.heki" 2>/dev/null \
  | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('interpretation','') or '')
except Exception: print('')" 2>/dev/null)

recurring=$("$HECKS" heki latest "$TMP/information/dream_interpretation.heki" 2>/dev/null \
  | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('recurring_theme','') or '')
except Exception: print('')" 2>/dev/null)

last_source=$("$HECKS" heki latest "$TMP/information/musing_mint.heki" 2>/dev/null \
  | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('last_source','') or '')
except Exception: print('')" 2>/dev/null)

echo "After interpret_dream.sh:"
echo "  dream_interpretation records: $interp_count"
echo "  musing_mint records:          $musing_count"
echo "  interpretation: $interpretation"
echo "  recurring_theme: $recurring"
echo "  last_source: $last_source"

[ "$interp_count" -ge 1 ] || fail "dream_interpretation.heki should have ≥1 record"
[ -n "$interpretation" ] || fail "interpretation is empty (Synthesize not dispatched)"
[ -n "$recurring" ] || fail "recurring_theme is empty (ExtractTheme not dispatched)"
[ "$musing_count" -ge 1 ] || fail "musing_mint.heki should have ≥1 record (no theme crossed ≥3)"
[ "$last_source" = "dream" ] || fail "last MintMusing should have source=dream, got '$last_source'"

echo "PASS — interpret_dream.sh extracts themes, synthesizes, and mints from recurring dreams"
exit 0
