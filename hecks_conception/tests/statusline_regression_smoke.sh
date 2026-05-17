#!/bin/bash
# statusline_regression_smoke.sh — post-2026-05-14 simplification.
#
# [antibody-exempt: hecks_conception/tests/statusline_regression_smoke.sh —
#  transitional shell smoke until every non-bluebook test file retires to
#  .behaviors with an executable runner. i499 (archived 2026-05-08) names
#  this shell as a Phase B target ; Phase A — `hecks-life test` /
#  `storehouse behaviors run` — is the keystone gap (runtime parses
#  .behaviors but doesn't execute them as live tests yet). Also retires
#  under i44 (statusline-as-bluebook) — the renderer is already in Rust
#  (rust/src/run_statusline/) but the catalog-driven emission contract
#  still lives outside a `Statusline` bluebook.]
#
# Post-simplification the statusline surfaces TWO signals only :
#   1. ❤️ <beats>          (heartbeat from tick.heki)
#   2. ✉️ <init>:<count> ...  (multi-inbox, omitted when all empty)
#
# The old shape's mood / fatigue / inventions / musings / provider /
# bulb / coherence-⚠ / last-dispatch breadcrumb were all stripped. This
# regression test now asserts the inverse : that NONE of those signals
# come back, and that the new multi-inbox shape renders.
#
# Symlink resolution (the original regression class) is still tested —
# Claude Code invokes the script via ~/.claude/statusline-command.sh
# and a broken readlink would still degrade the line.
#
# Assertions :
#   - Running via a symlinked path resolves to the real script dir
#   - Rendered line starts with one of the heart glyphs (❤️ alive / 🖤 dim)
#   - Mood, fatigue, breadcrumb, coherence, bulb, invention, provider
#     signals are all ABSENT from the output
#   - Multi-inbox listing renders as `✉️ gl:N` when a queued card exists
#   - When every inbox is empty, the envelope segment is suppressed
#     (no orphan separator, no leading whitespace before nothing)
#
# Exit 0 on pass, non-zero on fail.

set -u
set -m  # enable job control (process groups) for daemon isolation

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"

# i565 — worktree-aware MAIN_REPO anchor.
GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"
case "$GIT_COMMON" in
  /*) MAIN_REPO="$(cd "$(dirname "$GIT_COMMON")" && pwd)" ;;
  ?*) MAIN_REPO="$(cd "$REPO_ROOT/$(dirname "$GIT_COMMON")" && pwd)" ;;
  *)  MAIN_REPO="$REPO_ROOT" ;;
esac

if [ -n "${HECKS_BIN:-}" ]; then
  HECKS="$HECKS_BIN"
elif [ -x "$REPO_ROOT/rust/target/release/storehouse" ]; then
  HECKS="$REPO_ROOT/rust/target/release/storehouse"
elif [ -x "$REPO_ROOT/rust/target/debug/storehouse" ]; then
  HECKS="$REPO_ROOT/rust/target/debug/storehouse"
elif [ -x "$MAIN_REPO/rust/target/release/storehouse" ]; then
  HECKS="$MAIN_REPO/rust/target/release/storehouse"
elif [ -x "$MAIN_REPO/rust/target/debug/storehouse" ]; then
  HECKS="$MAIN_REPO/rust/target/debug/storehouse"
else
  echo "storehouse binary not found" >&2
  exit 1
fi
export STOREHOUSE="$HECKS"

fail=0
note_fail() { echo "  ✗ $*" >&2; fail=1; }
note_pass() { echo "  ✓ $*"; }

# Symlink to statusline-command.sh — all renders go through it so the
# symlink-resolution regression class stays covered.
SYMLINK_DIR="$(mktemp -d -t statusline_symlink.XXXXXX)"
# Hermetic HOME so the inbox walk doesn't see Chris's real ~/Projects
# inboxes during the run. Each render() seeds the inboxes it wants.
FAKE_HOME="$(mktemp -d -t statusline_fakehome.XXXXXX)"
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$SYMLINK_DIR" "$FAKE_HOME"' EXIT
ln -s "$CONCEPT_DIR/statusline-command.sh" "$SYMLINK_DIR/statusline-command.sh"

# seed_tick <info> <cycle> — seed only what awake-mode actually reads :
# tick.heki for beats + consciousness.heki for the awake/sleep branch.
# The mood / heartbeat / mint reads were removed when those signals
# were stripped, so the previous many-store seed is gone too.
seed_tick() {
  local info="$1" cycle="$2"
  "$HECKS" heki upsert "$info/tick.heki" \
    --reason "test setup : statusline regression — seed tick cycle for heartbeat read" \
    cycle="$cycle" >/dev/null
  "$HECKS" heki upsert "$info/consciousness.heki" \
    --reason "test setup : statusline regression — pin consciousness=attentive (awake branch)" \
    state="attentive" sleep_stage="" sleep_cycle=0 sleep_total=0 \
    sleep_summary="" is_lucid="no" >/dev/null
}

# seed_inbox <home> <project-rel-path> <ref> <status>
# Writes one markdown card with YAML frontmatter at the expected
# project-relative inbox path inside the fake HOME.
seed_inbox() {
  local home="$1" rel="$2" ref="$3" status="$4"
  local inbox="$home/$rel"
  mkdir -p "$inbox"
  cat > "$inbox/$ref.md" <<EOF
---
ref: $ref
status: $status
priority: normal
posted_at: 2026-05-14
source: statusline-regression-smoke
value: 'test fixture card'
---
body
EOF
}

# Reset the fake home so each scenario starts with no inboxes.
reset_home() {
  rm -rf "$FAKE_HOME"
  mkdir -p "$FAKE_HOME"
}

# render <cycle> → prints the statusline output (one line).
render() {
  local cycle="$1"
  local tmp info
  tmp="$(mktemp -d -t statusline_regression.XXXXXX)"
  info="$tmp/information"
  mkdir -p "$info"
  seed_tick "$info" "$cycle"
  printf '' | HOME="$FAKE_HOME" HECKS_INFO="$info" \
    bash -c 'bash "$0"' "$SYMLINK_DIR/statusline-command.sh" 2>&1
  rm -rf "$tmp"
}

# Assert the rendered line has the right shape and none of the
# stripped signals leak back in.
check_no_stripped_signals() {
  local label="$1" line="$2"
  if ! printf '%s' "$line" | grep -qE '^(❤️|🖤) '; then
    note_fail "[$label] line must start with a heart glyph — got: $line"
  fi
  for forbidden in \
    "focused" "groggy" "drifting" "refreshed" "excited" "curious" \
    "rested" "limber" "tuned" "tired" "exhausted" "spent" \
    "😊" "🤩" "🎯" "🤔" "🌀" "😐" \
    "🌿" "⚡" "🥱" "😩" "🫠" \
    "🛠️" "⚠" "💡" "🔬" "💭" "🤖" "🦙" \
    "(global)" ; do
    if printf '%s' "$line" | grep -qF -- "$forbidden"; then
      note_fail "[$label] stripped signal '$forbidden' leaked into: $line"
    fi
  done
  if printf '%s' "$line" | grep -q "No such file or directory"; then
    note_fail "[$label] 'No such file or directory' in output — symlink resolution broken"
  fi
}

# ---- Scenario 1 : heartbeat-only (all inboxes empty) ------------------
reset_home
out="$(render 1234)"
echo "[heartbeat-only] $out"
check_no_stripped_signals "heartbeat-only" "$out"
printf '%s' "$out" | grep -qF -- "1.23k" \
  || note_fail "[heartbeat-only] beats '1.23k' missing"
if printf '%s' "$out" | grep -qF -- "✉️"; then
  note_fail "[heartbeat-only] envelope must be suppressed when all inboxes empty — got: $out"
fi
if printf '%s' "$out" | grep -qF -- "•"; then
  note_fail "[heartbeat-only] dot separator must be suppressed when inbox list empty — got: $out"
fi

# ---- Scenario 2 : single seeded inbox (gl) ----------------------------
reset_home
seed_inbox "$FAKE_HOME" "Projects/hecks/hecks_conception/inbox" "test-1" "queued"
out="$(render 5678)"
echo "[gl-only] $out"
check_no_stripped_signals "gl-only" "$out"
printf '%s' "$out" | grep -qF -- "5.68k" \
  || note_fail "[gl-only] beats '5.68k' missing"
printf '%s' "$out" | grep -qF -- "✉️ gl:1" \
  || note_fail "[gl-only] expected '✉️ gl:1' — got: $out"
! printf '%s' "$out" | grep -qF -- "•" \
  || note_fail "[gl-only] dot separator must be gone — got: $out"
if printf '%s' "$out" | grep -qF -- "pi:"; then
  note_fail "[gl-only] empty pc inbox must NOT render — got: $out"
fi

# ---- Scenario 3 : multiple seeded inboxes (gl + pc + bb) --------------
reset_home
seed_inbox "$FAKE_HOME" "Projects/hecks/hecks_conception/inbox" "i1" "queued"
seed_inbox "$FAKE_HOME" "Projects/hecks/hecks_conception/inbox" "i2" "queued"
seed_inbox "$FAKE_HOME" "Projects/pigeoncoop/inbox" "p1" "queued"
seed_inbox "$FAKE_HOME" "Projects/bin-buddy/inbox" "b1" "queued"
seed_inbox "$FAKE_HOME" "Projects/bin-buddy/inbox" "b2" "queued"
seed_inbox "$FAKE_HOME" "Projects/bin-buddy/inbox" "b3" "queued"
# A non-queued card in pc must be ignored by the queued-status filter.
seed_inbox "$FAKE_HOME" "Projects/pigeoncoop/inbox" "p-closed" "closed"
out="$(render 999)"
echo "[multi-inbox] $out"
check_no_stripped_signals "multi-inbox" "$out"
printf '%s' "$out" | grep -qF -- "999" \
  || note_fail "[multi-inbox] beats '999' missing"
printf '%s' "$out" | grep -qF -- "gl:2" \
  || note_fail "[multi-inbox] expected 'gl:2' — got: $out"
printf '%s' "$out" | grep -qF -- "pi:1" \
  || note_fail "[multi-inbox] expected 'pi:1' (closed card filtered) — got: $out"
printf '%s' "$out" | grep -qF -- "bb:3" \
  || note_fail "[multi-inbox] expected 'bb:3' — got: $out"

if [ "$fail" = "0" ]; then
  echo "statusline_regression_smoke: OK"
  exit 0
else
  echo "statusline_regression_smoke: FAIL" >&2
  exit 1
fi
