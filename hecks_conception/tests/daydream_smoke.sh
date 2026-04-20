#!/bin/bash
# daydream_smoke.sh — smoke test for daydream.sh.
#
# Copies a minimal set of heki files to a tmpdir, links the aggregates
# directory, runs daydream.sh once, and asserts daydream.heki grew.
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
  echo "FAIL — can't find hecks-life binary"; exit 2
fi

TMP=$(mktemp -d -t daydream_smoke.XXXXXX)
trap "rm -rf $TMP" EXIT

mkdir -p "$TMP/information" "$TMP/aggregates"
ln -sf "$CONCEPT_DIR/aggregates/"*.bluebook "$TMP/aggregates/"

cat > "$TMP/world.hec" <<'EOF'
Hecks.world "DaydreamSmoke" do
  heki do
    dir "information"
  end
end
EOF

fail() { echo "FAIL — $1"; exit 1; }

# Count records before (the file may not exist → 0).
before=0
[ -f "$TMP/information/daydream.heki" ] && before=$("$HECKS" heki read "$TMP/information/daydream.heki" 2>/dev/null \
  | python3 -c "import json,sys
try: print(len(json.load(sys.stdin) or {}))
except Exception: print(0)")

HECKS_INFO="$TMP/information" \
HECKS_AGG="$TMP/aggregates" \
HECKS_BIN="$HECKS" \
HECKS_NURSERY="$CONCEPT_DIR/nursery" \
  bash "$CONCEPT_DIR/daydream.sh" \
  || fail "daydream.sh exited non-zero"

after=0
[ -f "$TMP/information/daydream.heki" ] && after=$("$HECKS" heki read "$TMP/information/daydream.heki" 2>/dev/null \
  | python3 -c "import json,sys
try: print(len(json.load(sys.stdin) or {}))
except Exception: print(0)")

echo "daydream.heki records: $before -> $after"

[ "$after" -gt "$before" ] || fail "daydream.heki did not grow (before=$before after=$after)"

# Sanity — synapse.heki should also have grown (new forming bond).
syn=0
[ -f "$TMP/information/synapse.heki" ] && syn=$("$HECKS" heki read "$TMP/information/synapse.heki" 2>/dev/null \
  | python3 -c "import json,sys
try: print(len(json.load(sys.stdin) or {}))
except Exception: print(0)")
echo "synapse.heki records: $syn"
[ "$syn" -ge 1 ] || fail "synapse.heki has no forming synapse"

echo "PASS — daydream.sh grew daydream.heki and added a forming synapse"
exit 0
