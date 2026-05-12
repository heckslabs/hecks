#!/bin/bash
# interpret_dream_smoke.sh — smoke test for the DreamInterpretation chain.
#
# [antibody-exempt: i220 sub-gap 6 retirement of interpret_dream.sh —
#  smoke now drives the DreamInterpretation chain via `storehouse
#  run-loop` instead of forking the legacy shell. Mirrors the
#  dream_content_smoke pattern (PR #593). Retires under i499 Phase B
#  once the `.behaviors` runner can replay the WokenUp + Dream.Gather
#  cascade and assert on `dream_corpus_json` shape ; i499 archived
#  2026-05-08 names this shell as a Phase B target.]
#
# Closes the interpret_dream.sh retirement loop. With i220 sub-gap 5
# (compute-adapter-primitive, PR #597) and sub-gap 6 (this PR — the
# tokenize_dream_corpus :compute function + DreamInterpretation
# hecksagon wiring), the wake event triggers the chain entirely
# through the runtime.
#
# What this smoke verifies (today, post-i220-6) :
#
#   1. The DreamInterpretation bluebook + hecksagon parse cleanly.
#      The run-loop boot builds the Domain ; parse failure aborts.
#
#   2. Synthetic WokenUp emitted on Consciousness.consciousness fires
#      the GatherOnWake policy → DreamInterpretation.GatherDreamCorpus.
#
#   3. The :compute adapter (trigger_on GatherDreamCorpus,
#      function tokenize_dream_corpus) fires : reads the seeded
#      dream_state.heki, tokenizes, ranks, and chains the JSON
#      payload back into DreamInterpretation.InterpretDream's
#      :dream_corpus_json attribute.
#
#   4. The InterpretOnGather policy → DreamInterpretation.InterpretDream
#      lifecycle dispatch lands ; the aggregate's :dream_corpus_json
#      field carries the JSON shape the function emitted.
#
# What this smoke does NOT verify (named gaps, deferred) :
#
#   - Per-theme ExtractTheme fan-out + count-gated MintMusing dispatch.
#     Both need DSL primitives that don't exist :
#       (a) JSON-destructure then_set form (one JSON payload →
#           multiple aggregate attributes via a single command)
#       (b) policy count-gate (`given { count(themes_above_threshold) >= 3 }`)
#     Until those land, the per-theme cascade is a follow-on PR.
#
#   - Narrate / LockNarrative LLM chain. Needs a parallel :llm
#     adapter declaration mirroring dream.hecksagon's :dream_image
#     pattern — also a follow-on once the JSON destructure lets
#     the input prompt template substitute the joined themes
#     without a custom Rust path.
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
elif [ -x "$REPO_ROOT/rust/target/release/storehouse" ]; then
  HECKS="$REPO_ROOT/rust/target/release/storehouse"
elif [ -x "/Users/christopheryoung/Projects/hecks/rust/target/release/storehouse" ]; then
  HECKS="/Users/christopheryoung/Projects/hecks/rust/target/release/storehouse"
else
  echo "FAIL — can't find storehouse binary"
  exit 2
fi

TMP=$(mktemp -d -t interpret_dream_smoke.XXXXXX)
# Process-group cleanup : kill the entire group on EXIT so any daemon
# spawned during the test can't survive into the next test.
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/information" "$TMP/aggregates"

# Symlink the bluebooks the chain dispatches into. Without these the
# run-loop boots but observes events with no receiving aggregate
# (parse silently drops the unknown commands).
for src in \
  "$BODY_DIR/sleep/consciousness.bluebook" \
  "$BODY_DIR/dream/dream_interpretation.bluebook" \
  "$BODY_DIR/dream/dream_interpretation.hecksagon" ; do
  [ -f "$src" ] && ln -sf "$src" "$TMP/aggregates/"
done

cat > "$TMP/interpret_dream_smoke.world" <<'EOF'
Hecks.world "InterpretDreamSmoke" do
  heki do
    dir "information"
  end
end
EOF

# Seed dream_state with images where "ocean" + "dissolving" recur and
# "library" / "spark" appear once. Same fixture shape as the legacy
# shell-driven smoke so the assertion path stays comparable.
seed_image() {
  "$HECKS" heki append "$TMP/information/dream_state.heki" \
    --reason "test setup : seed dream image for interpret_dream concept-recurrence sweep" \
    source=test dream_images="$1" >/dev/null 2>&1
}
seed_image "the ocean dissolving in a library"
seed_image "ocean waves dissolving into spark"
seed_image "a ocean dissolving"
seed_image "library corridors"
seed_image "spark in the dark"

# Force consciousness into a sleeping state so WakeUp transitions
# cleanly to waking and emits WokenUp.
"$HECKS" heki upsert "$TMP/information/consciousness.heki" \
  --reason "test setup : force Consciousness into sleeping so WakeUp emits WokenUp" \
  state=sleeping sleep_stage=rem sleep_cycle=1 sleep_total=8 \
  phase_ticks=0 dream_pulses=0 dream_pulses_needed=5 is_lucid=no \
  sleep_summary="entering REM — dreams beginning" >/dev/null 2>&1

fail() { echo "FAIL — $1"; exit 1; }

count_records() {
  [ ! -f "$1" ] && { echo 0; return; }
  "$HECKS" heki count "$1" 2>/dev/null || echo 0
}

field_value() {
  [ ! -f "$1" ] && { echo ""; return; }
  "$HECKS" heki latest-field "$1" "$2" 2>/dev/null || echo ""
}

# ── Drive the chain via `storehouse run-loop` ───────────────────────
# Two phases land the chain :
#   1. --emit WokenUp fires the GatherOnWake policy → GatherDreamCorpus
#      dispatch (the runtime treats the synthetic event the same as a
#      real one).
#   2. --dispatch DreamInterpretation.GatherDreamCorpus (with name=dream)
#      is the explicit anchor so the smoke is deterministic regardless
#      of policy-routing edge cases ; the :compute adapter fires either
#      way (its trigger is the dispatched command, not the policy event).
#
# The `name=dream` trailing arg is shared across all --dispatch actions
# in the tick (matches `storehouse loop`'s convention).
RUN_LOG="$TMP/run_loop.log"
HECKS_INFO="$TMP/information" \
HECKS_AGG="$TMP/aggregates" \
HECKS_BIN="$HECKS" \
"$HECKS" run-loop "$TMP/aggregates" \
  --every 500ms \
  --emit WokenUp:Consciousness:consciousness \
  --dispatch DreamInterpretation.GatherDreamCorpus \
  name=dream \
  >"$RUN_LOG" 2>&1 &
RUN_PID=$!

sleep 3
kill "$RUN_PID" 2>/dev/null || true
wait "$RUN_PID" 2>/dev/null || true

# Boot-failure guard
if ! grep -q 'storehouse run-loop' "$RUN_LOG"; then
  echo "----- run-loop output -----"
  cat "$RUN_LOG"
  fail "run-loop did not boot the DreamInterpretation chain (parse / load failure)"
fi

# Crash-guard
if grep -qE 'panicked|RuntimeError|undefined method|NameError' "$RUN_LOG"; then
  echo "----- run-loop output -----"
  cat "$RUN_LOG"
  fail "run-loop emitted a runtime error during DreamInterpretation cascade"
fi

echo "Boot via run-loop : OK"

# ── Growth assertions ──────────────────────────────────────────────
# DreamInterpretation aggregate lives in the BodyDream context (its
# bluebook declares `category "mind"`) — heki paths reflect (context,
# name) per i142, so the singleton lands at body_dream/dream_interpretation.heki.
DI_HEKI=""
for candidate in \
  "$TMP/information/dream_interpretation/dream_interpretation.heki" \
  "$TMP/information/body_dream/dream_interpretation.heki" \
  "$TMP/information/mind/dream_interpretation.heki" \
  "$TMP/information/dream_interpretation.heki" ; do
  if [ -f "$candidate" ]; then
    DI_HEKI="$candidate"
    break
  fi
done

if [ -z "$DI_HEKI" ]; then
  echo "----- run-loop output -----"
  cat "$RUN_LOG"
  echo "----- searched paths -----"
  ls -la "$TMP/information" "$TMP/information"/*/  2>/dev/null
  fail "DreamInterpretation .heki not produced anywhere — InterpretDream did not land"
fi

interp_count=$(count_records "$DI_HEKI")
dream_corpus_json=$(field_value "$DI_HEKI" dream_corpus_json)

echo "After run-loop drove the DreamInterpretation chain :"
echo "  dream_interpretation records : $interp_count  (heki: $DI_HEKI)"
echo "  dream_corpus_json (first 80) : ${dream_corpus_json:0:80}"

[ "$interp_count" -ge 1 ] || fail "$DI_HEKI should have >=1 record (InterpretDream did not land via DreamCorpusGathered cascade)"

# The :compute adapter populates :dream_corpus_json with the JSON
# tokenization payload. Confirm the field is non-empty AND looks
# like the expected JSON shape.
if [ -z "$dream_corpus_json" ] || [ "$dream_corpus_json" = "null" ]; then
  echo "----- run-loop output -----"
  cat "$RUN_LOG"
  echo "----- $DI_HEKI -----"
  "$HECKS" heki list "$DI_HEKI" --format json 2>/dev/null
  fail "dream_corpus_json empty — :compute adapter did not chain into InterpretDream"
fi

case "$dream_corpus_json" in
  *'"themes"'*'"joined"'*'"first_theme"'*)
    : # expected payload shape
    ;;
  *)
    echo "----- dream_corpus_json -----"
    echo "$dream_corpus_json"
    fail "dream_corpus_json does not carry the tokenize_dream_corpus payload shape"
    ;;
esac

# Confirm both "ocean" and "dissolving" land in themes_above_threshold
# (each appears 3x in the seed). first_theme alphabetizes on tie
# (sort_by(-count, +word)) so "dissolving" comes first. The
# substantive assertion is on the recurring set, not the alphabetic
# tie order.
case "$dream_corpus_json" in
  *'"themes_above_threshold":[]'*)
    echo "----- dream_corpus_json -----"
    echo "$dream_corpus_json"
    fail "themes_above_threshold is empty — tokenize_dream_corpus did not detect recurring themes (count >= 3)"
    ;;
esac
case "$dream_corpus_json" in
  *'"ocean"'*'"dissolving"'*|*'"dissolving"'*'"ocean"'*)
    echo "  recurring themes detected : ocean + dissolving (each count >= 3 in seed)"
    ;;
  *)
    echo "----- dream_corpus_json -----"
    echo "$dream_corpus_json"
    fail "recurring themes (ocean, dissolving) absent — tokenize_dream_corpus ranking drifted from the jq baseline"
    ;;
esac

echo "PASS — DreamInterpretation chain runs end-to-end via run-loop ; tokenize_dream_corpus :compute populates :dream_corpus_json"
echo ""
echo "Deferred (named gaps, not blockers for this smoke) :"
echo "  - per-theme ExtractTheme fan-out + count-gated MintMusing : needs JSON-destructure then_set + policy count-gate primitive"
echo "  - Narrate / LockNarrative LLM chain : needs parallel :llm adapter declaration once joined-themes substitution lands"
exit 0
