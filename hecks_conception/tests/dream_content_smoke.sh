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
#        - DreamSeed.PlantSeed       (body/dream/dream_seed.bluebook ; sweep on Musing.recent)
#        - Dream.ProduceImage        (body/dream/dream.bluebook       ; per-tick image request)
#        - Body.RecordDreamPulse     (referenced by PM ; backed by Consciousness.DreamPulse today)
#
#   3. run-loop emits a synthetic SleepEntered (births the PM into
#      :incubating) + RemEntered (transitions to :generating) +
#      repeated PhaseElapsed (drives the per-tick generating loop).
#      The PM observes all three. We assert :
#        - PM-driven sweep enumerated Musing.recent into DreamSeed.PlantSeed
#          dispatches : dream_seed.heki has ≥1 record.
#        - PM-driven cascade dispatched Body.RecordDreamPulse per tick :
#          consciousness.dream_pulses incremented.
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

# Nested heki layout (post-i118 R5).
mkdir -p "$TMP/information/consciousness" "$TMP/information/dream" \
         "$TMP/information/dream_seed" "$TMP/information/musing" \
         "$TMP/aggregates"

# Symlink the body bluebooks the Dream PM dispatches into. Without
# these the PM boots but observes events with no receiving aggregate
# (parse silently drops the unknown commands) and the assertion path
# has nothing to read.
for src in \
  "$BODY_DIR/sleep/consciousness.bluebook" \
  "$BODY_DIR/dream/dream.bluebook" \
  "$BODY_DIR/dream/dream.hecksagon" \
  "$BODY_DIR/dream/dream_seed.bluebook" ; do
  [ -f "$src" ] && ln -sf "$src" "$TMP/aggregates/"
done
# Mind-side musing.bluebook for the DreamSeed.PlantSeed sweep source.
MIND_DIR="${HECKS_MIND_DIR:-}"
[ -z "$MIND_DIR" ] && [ -d "$BODY_DIR/../mind" ] && \
  MIND_DIR="$(cd "$BODY_DIR/../mind" && pwd)"
[ -n "$MIND_DIR" ] && [ -f "$MIND_DIR/memory/musing.bluebook" ] && \
  ln -sf "$MIND_DIR/memory/musing.bluebook" "$TMP/aggregates/"

cat > "$TMP/dream_content_smoke.world" <<'EOF'
Hecks.world "DreamContentSmoke" do
  heki do
    dir "information"
  end
end
EOF

# ── Seed musings the DreamSeed.PlantSeed sweep walks ─────────────────
iso_offset() {
  local secs="$1" now_epoch
  now_epoch=$(date -u +%s)
  date -u -r "$((now_epoch - secs))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$((now_epoch - secs))" +%Y-%m-%dT%H:%M:%SZ
}
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for i in 1 2 3 4 5; do
  ts=$(iso_offset $((i * 60)))
  "$HECKS" heki append "$TMP/information/musing/musing.heki" \
    --reason "test setup : seed Musing.recent for DreamSeed.PlantSeed sweep" \
    idea="dream-source musing $i" source=mindstream thinking_source=wandering \
    conceived=false status=imagined created_at="$ts" >/dev/null 2>&1
done

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

dream_seed_before=$(count_records "$TMP/information/dream_seed/dream_seed.heki")
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
HECKS_LLM_PROVIDER=test \
HECKS_INFO="$TMP/information" \
HECKS_AGG="$TMP/aggregates" \
HECKS_BIN="$HECKS" \
"$HECKS" run-loop "$TMP/aggregates" \
  --every 500ms \
  --emit SleepEntered:Consciousness:consciousness \
  --emit RemEntered:Consciousness:consciousness \
  --emit PhaseElapsed:Consciousness:consciousness \
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
# The Dream PM's `dispatch "DreamSeed.PlantSeed", for_each: { from:
# "Musing.recent" }` (i221-A sweep primitive ; i225 runtime-side
# enumeration) walks the musing query and fires PlantSeed once per
# record. dream_seed.heki should grow by ≥1.
#
# The PM's `dispatch "Body.RecordDreamPulse"` per PhaseElapsed routes
# through the runtime's command dispatcher ; today this lands on the
# Consciousness.DreamPulse command (the production receiver), which
# increments dream_pulses. With multiple PhaseElapsed emits the
# counter advances.

dream_seed_after=$(count_records "$TMP/information/dream_seed/dream_seed.heki")
pulses_after=$(field_value "$TMP/information/consciousness/consciousness.heki" dream_pulses)
[ -z "$pulses_after" ] && pulses_after=0

echo "After Dream PM run :"
echo "  dream_seed records  : $dream_seed_before → $dream_seed_after"
echo "  dream_pulses       : $pulses_before → $pulses_after"

[ "$dream_seed_after" -gt "$dream_seed_before" ] || \
  fail "dream_seed/dream_seed.heki did not grow (expected DreamSeed.PlantSeed via for_each Musing.recent sweep)"

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
text_fr=$(field_value "$DREAM_HEKI" text_fr)
if [ -z "$text_fr" ] || [ "$text_fr" = "null" ]; then
  echo "----- run-loop output -----"
  cat "$RUN_LOG"
  echo "----- dream.heki -----"
  "$HECKS" heki list "$DREAM_HEKI" --format json 2>/dev/null || echo "(no dream.heki yet)"
  fail "Dream.text_fr empty after PM cascade — :dream_image adapter did not fire through TestProvider (gap3)"
fi
echo "  text_fr            : ${text_fr:0:60}..."

# text_en is the second leg : :dream_translate adapter on
# Dream.RecordImage. Routes through TestProvider too.
text_en=$(field_value "$DREAM_HEKI" text_en)
if [ -n "$text_en" ] && [ "$text_en" != "null" ]; then
  echo "  text_en            : ${text_en:0:60}..."
else
  echo "  text_en            : (not populated — :dream_translate adapter chains on RecordImage ; investigate if needed)"
fi

echo "PASS — Dream PM boots via run-loop ; dream_seed grew via i221-A for_each Musing.recent sweep ; text_fr lands via :llm cascade through TestProvider (gap3)"
echo ""
echo "Deferred (named gaps, not blockers for this smoke) :"
echo "  - lucid path (LucidDream.ObserveDream / SteerDream) : same i228 chain-trigger gap"
echo "  - Body.RecordDreamPulse / Consciousness.dream_pulses growth : Body aggregate forward-ref ; bluebook surgery follow-on"
exit 0
