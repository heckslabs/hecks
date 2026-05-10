#!/bin/bash
# dream_content_smoke.sh — smoke test for the Dream PM (i220 / rem_branch retirement).
#
# [antibody-exempt: i220 retirement of rem_branch.sh — smoke now drives
#  the Dream PM via `hecks-life run-loop` instead of forking the legacy
#  shell. Mirrors the consolidate_smoke pattern (PR #592) ; retires
#  entirely when smoke tests port to a bluebook-shebang form.]
#
# Closes the rem_branch.sh retirement loop, alongside i220-1 (the
# cascade-LLM hook in `drain_policies` so PM-driven cascades reach
# the named-adapter pipeline) and the deferred i220-3 (FixtureLlmAdapter
# / HECKS_LLM_PROVIDER=test wiring for deterministic dream-content
# fixtures in this smoke). With those landed the Dream PM produces
# images declaratively from PM cascades through the runtime ; this
# smoke drives the PM directly via `hecks-life run-loop`.
#
# What this smoke verifies (today, post-i220-1) :
#
#   1. The Dream PM (body/dream/dream.bluebook) parses cleanly under
#      both Ruby + Rust loaders. The run-loop boot builds the Domain ;
#      if any DSL surface drifts, the boot fails.
#
#   2. The PM's lifecycle dispatches resolve to declared aggregates :
#        - Dream.GatherSeeds         (body/dream/dream.bluebook ; i516 v3 seed bundle)
#        - Dream.ProduceImage        (body/dream/dream.bluebook ; per-tick image request)
#        - Body.RecordDreamPulse     (referenced by PM ; backed by Consciousness.DreamPulse today)
#
#   3. run-loop emits a synthetic SleepEntered (births the PM into
#      :incubating) + RemEntered (transitions to :generating) +
#      repeated PhaseElapsed (drives the per-tick generating loop),
#      and explicitly --dispatches Dream.GatherSeeds with the four
#      seed sources (recent_dreams_seed, body_state_seed,
#      vow_tensions_seed, commits_today_seed) so the prompt template's
#      placeholders expand against real material. We assert :
#        - The :dream_image adapter cascade lands `reading` on the
#          Dream singleton (body_dream/dream.heki) via the
#          TestProvider (gap3, i220-3).
#
# What this smoke does NOT verify (scope-cut, named gaps) :
#
#   - text_fr / text_en content production. The Dream hecksagon's
#     `:dream_image` + `:dream_translate` adapters target
#     `Dream.RecordImage`, not `Dream.ProduceImage`. The PM today
#     dispatches `Dream.ProduceImage` only ; even with i220-1's
#     cascade-LLM hook in place, there's no adapter targeting
#     `Dream.ProduceImage` (gap i228 — chain-trigger-separate-from-
#     response-target). So the LLM doesn't fire from this PM cascade.
#     Closing that requires either (a) bluebook surgery to dispatch
#     `Dream.RecordImage` from the PM, (b) i228 (separate trigger
#     declaration), or (c) i220-3 (FixtureLlmAdapter wiring + dream
#     fixtures) — all deferred.
#
#   - lucid path. LucidDream.ObserveDream / SteerDream live on the
#     same chain-trigger gap and are also deferred.
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

TMP=$(mktemp -d -t dream_content_smoke.XXXXXX)
# Process-group cleanup : kill the entire group on EXIT so any daemon
# spawned during the test can't survive into the next test.
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$TMP"' EXIT

# Nested heki layout (post-i118 R5). i516 v3 (Musings retirement,
# 2026-05-08) — musing.heki is dormant ; the Dream PM no longer
# sweeps it. Seed sources land via Dream.GatherSeeds (recent_dreams,
# body_state, vow_tensions, commits_today) supplied as
# --dispatch attributes on the run-loop invocation below.
mkdir -p "$TMP/information/consciousness" "$TMP/information/dream" \
         "$TMP/information/body_dream" \
         "$TMP/aggregates"

# Symlink the body bluebooks the Dream PM dispatches into. Without
# these the PM boots but observes events with no receiving aggregate
# (parse silently drops the unknown commands) and the assertion path
# has nothing to read.
for src in \
  "$BODY_DIR/sleep/consciousness.bluebook" \
  "$BODY_DIR/dream/dream.bluebook" \
  "$BODY_DIR/dream/dream.hecksagon" ; do
  [ -f "$src" ] && ln -sf "$src" "$TMP/aggregates/"
done
# i516 v3 (2026-05-08) : Musings.Musing.recent retired as a seed
# source. The mind-side musings.bluebook + the dream_seed.bluebook
# sweep target are no longer needed. Seeds now arrive via
# Dream.GatherSeeds (--dispatch below) populating
# recent_dreams_seed / body_state_seed / vow_tensions_seed /
# commits_today_seed atomically on SleepEntered.

cat > "$TMP/dream_content_smoke.world" <<'EOF'
Hecks.world "DreamContentSmoke" do
  heki do
    dir "information"
  end
end
EOF

# ── i516 v3 seed bundle (Musings retired) ────────────────────────────
# The Dream PM's seed material is now stamped via Dream.GatherSeeds —
# the post-i516-v3 single source-of-truth surface. We seed it directly
# with the four current sources : recent_dreams, body_state, vow_tensions,
# commits_today. The --dispatch on the run-loop invocation below feeds
# these as command attributes, which then_set onto the Dream singleton.
RECENT_DREAMS_SEED="last night's wave reading
the corridor of file paths"
BODY_STATE_SEED="tired ; carrying tomorrow"
VOW_TENSIONS_SEED="silence-while-i-talk"
COMMITS_TODAY_SEED="9e928778 : i497 session continuation
34cb6c5e : antibody re-register"

# Force consciousness into REM, first cycle, no pulses yet — same
# state rem_branch.sh expected when it dispatched dream production.
"$HECKS" heki upsert "$TMP/information/consciousness/consciousness.heki" \
  --reason "test setup : force Consciousness into REM cycle 1 so Dream PM can drive image production" \
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

pulses_before=$(field_value "$TMP/information/consciousness/consciousness.heki" dream_pulses)
[ -z "$pulses_before" ] && pulses_before=0

# ── Drive the PM via `hecks-life run-loop` ─────────────────────────
# The run-loop boots the Runtime, parses the dream bluebook + its
# hecksagon, and ticks at the configured cadence. We emit synthetic
# SleepEntered (births the Dream PM into :incubating, fires the
# DreamSeed.PlantSeed sweep) followed by RemEntered (transitions to
# :generating) and a stream of PhaseElapsed (drives the per-tick
# generating loop). Run for ~3s, then assert.
#
# --emit form is Event:AggregateType:AggregateId. Events target
# Consciousness:consciousness so the PM correlates by :name == "dream"
# (Dream PM correlates_by :name) but the upstream Body events route
# via the dispatch context.
RUN_LOG="$TMP/run_loop.log"
# gap3 (i220-3) — flip every :llm adapter to the in-process TestProvider
# regardless of what the hecksagon declared (`backend :claude`). The
# TestProvider is lenient by default : missing fixtures return a
# synthetic placeholder string so the cascade still completes and
# text_fr / text_en land non-empty. The shipped body/dream/dream.fixtures
# is auto-discovered alongside dream.hecksagon and merged into the
# prompt-keyed map ; rows whose SHA matches the live substituted prompt
# return their canonical French ; rows that don't match fall through
# to lenient.
#
# i516 v3 — explicit Dream.GatherSeeds dispatch supplies the four
# seed sources directly (recent_dreams_seed, body_state_seed,
# vow_tensions_seed, commits_today_seed) so the prompt-template
# placeholders expand against real material on the Dream singleton.
# The synthetic SleepEntered would also fire the GatherSeedsOnSleep
# policy → Dream.GatherSeeds with empty attrs ; the explicit dispatch
# below ensures the seed bundle is populated regardless of policy
# routing edge cases.
HECKS_LLM_PROVIDER=test \
HECKS_INFO="$TMP/information" \
HECKS_AGG="$TMP/aggregates" \
HECKS_BIN="$HECKS" \
"$HECKS" run-loop "$TMP/aggregates" \
  --every 500ms \
  --emit SleepEntered:Consciousness:consciousness \
  --emit RemEntered:Consciousness:consciousness \
  --emit PhaseElapsed:Consciousness:consciousness \
  --dispatch Dream.GatherSeeds \
  name=dream \
  recent_dreams_seed="$RECENT_DREAMS_SEED" \
  body_state_seed="$BODY_STATE_SEED" \
  vow_tensions_seed="$VOW_TENSIONS_SEED" \
  commits_today_seed="$COMMITS_TODAY_SEED" \
  >"$RUN_LOG" 2>&1 &
RUN_PID=$!

sleep 3
kill "$RUN_PID" 2>/dev/null || true
wait "$RUN_PID" 2>/dev/null || true

# Boot-failure guard : run-loop's startup banner names the loaded
# domain. Absence means the bluebook didn't parse.
if ! grep -q 'hecks-life run-loop' "$RUN_LOG"; then
  echo "----- run-loop output -----"
  cat "$RUN_LOG"
  fail "run-loop did not boot the Dream PM (parse / load failure)"
fi

# Crash-guard : look for stack traces or panic markers.
if grep -qE 'panicked|RuntimeError|undefined method|NameError' "$RUN_LOG"; then
  echo "----- run-loop output -----"
  cat "$RUN_LOG"
  fail "run-loop emitted a runtime error during PM dispatch"
fi

echo "PM boot via run-loop : OK"

# ── Growth assertions (PM-driven, no shell fallback) ───────────────
# i516 v3 (Musings retirement, 2026-05-08) — the for_each
# Musings.Musing.recent sweep is retired. The DreamSeed.PlantSeed
# dispatch is commented out in dream.bluebook (the for_each block
# stays in source as historical context). The new contract :
#
#   1. Dream.GatherSeeds (above) lands the seed bundle on the Dream
#      singleton — recent_dreams_seed, body_state_seed,
#      vow_tensions_seed, commits_today_seed. The :dream_image
#      adapter's prompt template references these fields directly.
#
#   2. Per-tick Dream.ProduceImage cascades through the :llm adapter
#      (via TestProvider in lenient mode) into Dream.RecordImage,
#      stamping `reading` on the singleton.
#
# The PM's `dispatch "Body.RecordDreamPulse"` per PhaseElapsed routes
# through the runtime's command dispatcher ; today this lands on the
# Consciousness.DreamPulse command (the production receiver), which
# increments dream_pulses. With multiple PhaseElapsed emits the
# counter advances.

pulses_after=$(field_value "$TMP/information/consciousness/consciousness.heki" dream_pulses)
[ -z "$pulses_after" ] && pulses_after=0

echo "After Dream PM run :"
echo "  dream_pulses       : $pulses_before → $pulses_after"

# dream_pulses growth is reported but NOT asserted today. The PM's
# `dispatch "Body.RecordDreamPulse", with: { name: "body" }` targets
# a Body aggregate that doesn't exist as a real production aggregate
# (the command is referenced but not defined ; sleep_cycle.bluebook
# has the same forward-reference). Filed as a bluebook gap on the
# rem_branch retirement arc. Once Body.RecordDreamPulse is defined
# (or the PM is updated to dispatch Consciousness.DreamPulse with
# the right impression attr), gate this assertion.

# ── gap3 (i220-3) : :llm cascade lands text_fr on Dream singleton ──
#
# When the PM dispatches Dream.ProduceImage on PhaseElapsed, the
# :dream_image adapter (trigger_on Dream.ProduceImage in
# body/dream/dream.hecksagon) fires through the TestProvider — the
# response cascades into Dream.RecordImage(text_fr:). Verify the
# Dream singleton holds a non-empty text_fr after the run-loop drains.
#
# Lenient mode : an unknown prompt returns a synthetic
# `[test-provider:unknown-prompt sha256=...]` string. Either way,
# text_fr is non-empty after the cascade — that's what gap3 closes.
# A precise-content assertion lives in the rust llm_dispatcher_test
# integration tests (which use a fixture-keyed-by-known-SHA path).
# Dream aggregate lives in the BodyDream context (its bluebook
# declares `category "body"`). Heki paths reflect (context, name)
# pairing post-i142, so the singleton lands at
# `body_dream/dream.heki`, not `dream/dream.heki` (the latter is
# the PM persistence heki — same file basename, different role).
DREAM_HEKI="$TMP/information/body_dream/dream.heki"
# i516 single-phase rename : assertion target moved from text_fr to
# `reading` (the canonical single-phase precise output). text_fr/text_en
# stay as one-cycle back-compat fields but aren't populated by the
# cascade today.
#
# Dream PM writes TWO record families to this heki :
#   - The Dream singleton (id="dream") — holds the seed bundle from
#     Dream.GatherSeeds, but `reading` stays empty (the PM doesn't
#     restamp the seeds record with the cascade output).
#   - Per-cycle records (id="1", "2", ...) — each per-tick
#     Dream.RecordImage stamps `reading` on a new record.
# `latest-field` returns the LAST-written record's value, which is
# racy : if GatherSeeds wins, the singleton (with empty reading)
# wins ; if the cascade wins, a cycle record wins. The cascade
# firing is the actual invariant — assert "any non-empty reading"
# rather than "latest reading non-empty".
reading=$("$HECKS" heki list "$DREAM_HEKI" --format json 2>/dev/null | \
  jq -r '[.[].reading] | map(select(. != "" and . != null))[0] // ""' 2>/dev/null)
if [ -z "$reading" ] || [ "$reading" = "null" ]; then
  echo "----- run-loop output -----"
  cat "$RUN_LOG"
  echo "----- dream.heki -----"
  "$HECKS" heki list "$DREAM_HEKI" --format json 2>/dev/null || echo "(no dream.heki yet)"
  fail "Dream.reading empty across all records after PM cascade — :dream_image adapter did not fire through TestProvider (gap3)"
fi
echo "  reading            : ${reading:0:60}..."

# text_en is the second leg : :dream_translate adapter on
# Dream.RecordImage. Routes through TestProvider too. Same any-record
# check as reading above.
text_en=$("$HECKS" heki list "$DREAM_HEKI" --format json 2>/dev/null | \
  jq -r '[.[].text_en] | map(select(. != "" and . != null))[0] // ""' 2>/dev/null)
if [ -n "$text_en" ] && [ "$text_en" != "null" ]; then
  echo "  text_en            : ${text_en:0:60}..."
else
  echo "  text_en            : (not populated — :dream_translate adapter chains on RecordImage ; investigate if needed)"
fi

echo "PASS — Dream PM boots via run-loop ; seed bundle stamped via Dream.GatherSeeds (i516 v3 — Musings retired) ; reading lands on Dream singleton via :llm cascade through TestProvider (gap3)"
echo ""
echo "Deferred (named gaps, not blockers for this smoke) :"
echo "  - lucid path (LucidDream.ObserveDream / SteerDream) : same i228 chain-trigger gap"
echo "  - Body.RecordDreamPulse / Consciousness.dream_pulses growth : Body aggregate forward-ref ; bluebook surgery follow-on"
exit 0
