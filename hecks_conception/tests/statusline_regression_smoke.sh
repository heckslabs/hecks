#!/bin/bash
# statusline_regression_smoke.sh — catch the regression classes that have
# bit us twice in the 2026-04-22 arc:
#
#   1. SYMLINK RESOLUTION — Claude Code runs the script via a symlink
#      (~/.claude/statusline-command.sh → hecks_conception/). If $0 is
#      used without readlink the script can't find status_coherence.sh,
#      coherence check errors non-zero, and the mood icon degrades to ⚠
#      on every render. This bit us silently. (PR #289 fixed.)
#
#   2. MISSING MOOD ICON CASE — body.bluebook emits six mood strings
#      (refreshed, groggy, excited, focused, curious, drifting). The
#      script's case statement has to track them; if a mood is missing,
#      the icon falls through to 😐 and we quietly lose a signal.
#      (PR #286 added the three missing ones.)
#
#   3. MISSING FATIGUE ICON — same shape for fatigue_state.
#
# Transitional: this is a shell smoke for a shell script. Retires when
# inbox i44 (statusline-as-bluebook) ships, at which point both the
# renderer and its tests live in .bluebook + .behaviors and drift
# becomes structurally impossible.
#
# Assertions:
#   - Running via a symlinked path resolves to the real script dir
#   - Rendered line starts with ☀️ Miette in awake state
#   - Mood icon renders for every mood body.bluebook emits (6 scenarios)
#   - Fatigue icon renders for every fatigue_state (5 scenarios)
#   - No ⚠ glyph when body state is coherent (sanity)
#   - No literal "No such file or directory" string anywhere in output
#
# Exit 0 on pass, non-zero on fail.

set -u
set -m  # enable job control (process groups) for daemon isolation

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"

if [ -n "${HECKS_BIN:-}" ]; then
  HECKS="$HECKS_BIN"
elif [ -x "$REPO_ROOT/rust/target/release/hecks-life" ]; then
  HECKS="$REPO_ROOT/rust/target/release/hecks-life"
elif [ -x "$REPO_ROOT/rust/target/debug/hecks-life" ]; then
  HECKS="$REPO_ROOT/rust/target/debug/hecks-life"
else
  echo "hecks-life binary not found" >&2
  exit 1
fi
export HECKS_LIFE="$HECKS"

fail=0
note_fail() { echo "  ✗ $*" >&2; fail=1; }
note_pass() { echo "  ✓ $*"; }

# Create a symlink to statusline-command.sh. All scenarios invoke through
# the symlink so the symlink resolution bug (#1) is tested on every run.
SYMLINK_DIR="$(mktemp -d -t statusline_symlink.XXXXXX)"
# Process-group cleanup : kill the entire group on EXIT so any daemon
# spawned during the test can't survive into the next test.
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$SYMLINK_DIR"' EXIT
ln -s "$CONCEPT_DIR/statusline-command.sh" "$SYMLINK_DIR/statusline-command.sh"

# seed <info-dir> <mood> <fatigue_state> <pulses_since_sleep>
# Writes coherent body state per status_coherence.sh invariants 1 + 3.
seed() {
  local info="$1" mood="$2" fstate="$3" pulses="$4"
  "$HECKS" heki upsert "$info/mood.heki" \
    --reason "test setup : statusline regression fixture — seed mood for coherence invariants" \
    current_state="$mood" creativity_level=0.7 precision_level=0.8 >/dev/null
  "$HECKS" heki upsert "$info/heartbeat.heki" \
    --reason "test setup : statusline regression fixture — seed heartbeat fatigue state" \
    fatigue=0.3 fatigue_state="$fstate" pulse_rate=1.0 \
    flow_rate="steady" pulses_since_sleep="$pulses" >/dev/null
  "$HECKS" heki upsert "$info/consciousness.heki" \
    --reason "test setup : statusline regression fixture — seed attentive consciousness" \
    state="attentive" sleep_stage="" sleep_cycle=8 sleep_total=8 \
    sleep_summary="" is_lucid="no" >/dev/null
  "$HECKS" heki upsert "$info/tick.heki" \
    --reason "test setup : statusline regression fixture — seed tick cycle for monotonicity invariant" \
    cycle=555 >/dev/null
  # Seed .tick_baseline to match so invariant 4 (tick monotonicity) passes.
  printf '%s %s\n' "$(date +%s)" 555 > "$info/.tick_baseline"
}

# render <mood> <fatigue_state> <pulses> → prints the statusline output
render() {
  local mood="$1" fstate="$2" pulses="$3"
  local tmp info
  tmp="$(mktemp -d -t statusline_regression.XXXXXX)"
  info="$tmp/information"
  mkdir -p "$info"
  seed "$info" "$mood" "$fstate" "$pulses"
  printf '' | HECKS_INFO="$info" bash -c 'bash "$0"' "$SYMLINK_DIR/statusline-command.sh" 2>&1
  rm -rf "$tmp"
}

# Shared assertion harness. The statusline shape is :
#   <heart_glyph> <beats> <mood_icon> <mood> [<fatigue_icon> <fatigue>] 💭 <count> [✉️ <inbox>] <provider>
# The historical "☀️ Miette ..." prefix retired ; the heart glyph is
# now the prefix in awake mode. We assert the line starts with one of
# the heart glyphs (❤️ alive / 🖤 dim) instead.
check_line() {
  local label="$1" line="$2"
  if ! printf '%s' "$line" | grep -qE '^(❤️|🖤) '; then
    note_fail "[$label] rendered line did not start with a heart glyph — got: $line"
  fi
  if printf '%s' "$line" | grep -q "⚠"; then
    note_fail "[$label] ⚠ glyph in output — coherence check failed (likely the symlink regression) — got: $line"
  fi
  if printf '%s' "$line" | grep -q "No such file or directory"; then
    note_fail "[$label] 'No such file or directory' in output — symlink resolution broken"
  fi
}

# ---- Mood scenarios (one per mood body.bluebook emits) ------------------
for scenario in \
  "refreshed:😊:limber:0" \
  "excited:🤩:tuned:300" \
  "focused:🎯:tuned:300" \
  "curious:🤔:normal:700" \
  "drifting:🌀:tired:1200" \
  "groggy:😵‍💫:normal:700"; do
  IFS=: read -r mood icon fstate pulses <<< "$scenario"
  out="$(render "$mood" "$fstate" "$pulses")"
  echo "[mood=$mood] $out"
  check_line "mood=$mood" "$out"
  printf '%s' "$out" | grep -qF -- "$icon" || note_fail "[mood=$mood] icon '$icon' missing"
  printf '%s' "$out" | grep -qF -- "$mood" || note_fail "[mood=$mood] word '$mood' missing"
done

# ---- Fatigue scenarios (one per fatigue_state with a non-empty icon) ----
# 'normal' has an intentionally empty fatigue_icon so we skip it.
for scenario in \
  "limber:⚡:0" \
  "tuned:🎯:300" \
  "tired:🥱:1200" \
  "exhausted:😩:1600" \
  "spent:🫠:1900"; do
  IFS=: read -r fstate icon pulses <<< "$scenario"
  # For coherence, we need mood to match the fatigue rung — refreshed
  # requires limber|tuned. For rungs above tuned, use 'curious' or
  # 'drifting' which don't trigger invariant 1.
  mood="curious"
  [ "$fstate" = "limber" ] && mood="refreshed"
  [ "$fstate" = "tuned" ] && mood="focused"
  out="$(render "$mood" "$fstate" "$pulses")"
  echo "[fatigue=$fstate] $out"
  check_line "fatigue=$fstate" "$out"
  printf '%s' "$out" | grep -qF -- "$icon" || note_fail "[fatigue=$fstate] icon '$icon' missing"
  printf '%s' "$out" | grep -qF -- "$fstate" || note_fail "[fatigue=$fstate] word '$fstate' missing"
done

# ---- Fallback scenario: unknown mood → 😐, no crash ---------------------
out="$(render 'totally_made_up_mood' 'normal' 700)"
echo "[fallback] $out"
check_line "fallback" "$out"
printf '%s' "$out" | grep -qF -- "😐" || note_fail "[fallback] expected 😐 fallback icon"

if [ "$fail" = "0" ]; then
  echo "statusline_regression_smoke: OK"
  exit 0
else
  echo "statusline_regression_smoke: FAIL" >&2
  exit 1
fi
