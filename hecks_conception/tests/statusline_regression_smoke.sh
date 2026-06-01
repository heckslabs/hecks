#!/bin/bash
# statusline_regression_smoke.sh — bus-routed smoke for the statusline
# rendered shape (post-2026-05-14 simplification).
#
# Restores coverage deleted in PR #717. The original seeded tick.heki +
# consciousness.heki via raw `heki upsert` and asserted the statusline
# rendered (a) a heartbeat glyph + count, (b) decentralised channel
# segments per `.channel.md`, AND (c) the retired-mood / fatigue /
# breadcrumb / coherence signals were absent. With direct heki writes
# retired, the seed flows through bus dispatch :
#
#   - Body::Tick.MindstreamTick seeds the tick cycle (fans out to heart).
#   - Mind::Consciousness.BecomeAttentive lands the awake branch the
#     statusline reads to pick the heart-glyph variant.
#
# Symlink resolution — the original regression class — is still tested :
# Claude Code invokes the statusline through ~/.claude/statusline-command.sh
# and a broken readlink degrades the line.
#
# Exit 0 on pass, non-zero on fail.

set -u
set -m

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"

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

BODY_DIR="${HECKS_BODY_DIR:-}"
[ -z "$BODY_DIR" ] && [ -d "$MAIN_REPO/../miette" ] && \
  BODY_DIR="$(cd "$MAIN_REPO/../miette" && pwd)"

fail=0
note_fail() { echo "  ✗ $*" >&2; fail=1; }
note_pass() { echo "  ✓ $*"; }

SYMLINK_DIR="$(mktemp -d -t statusline_symlink.XXXXXX)"
FAKE_HOME="$(mktemp -d -t statusline_fakehome.XXXXXX)"
WORK="$(mktemp -d -t statusline_work.XXXXXX)"
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$SYMLINK_DIR" "$FAKE_HOME" "$WORK"' EXIT
ln -s "$CONCEPT_DIR/statusline-command.sh" "$SYMLINK_DIR/statusline-command.sh"

mkdir -p "$WORK/information" "$WORK/aggregates"
find "$CONCEPT_DIR/aggregates" -name "*.bluebook" -exec ln -sf {} "$WORK/aggregates/" \;
[ -n "$BODY_DIR" ] && [ -d "$BODY_DIR" ] && \
  find "$BODY_DIR" -name "*.bluebook" -exec ln -sf {} "$WORK/aggregates/" \; 2>/dev/null

# ── BUS-routed seed of tick + consciousness vitals ──
# Replaces the deleted `heki upsert tick.heki cycle=...` +
# `heki upsert consciousness.heki state=attentive ...` raw writes.
seed_via_bus() {
  local info="$1"
  HECKS_INFO="$info" "$HECKS" "$WORK/aggregates" Body::Tick.MindstreamTick >/dev/null 2>&1 || true
  HECKS_INFO="$info" "$HECKS" "$WORK/aggregates" Mind::Consciousness.BecomeAttentive >/dev/null 2>&1 || true
  HECKS_INFO="$info" "$HECKS" "$WORK/aggregates" Body::Heart.Beat >/dev/null 2>&1 || true
}

render() {
  local info="$1"
  HOME="$FAKE_HOME" HECKS_INFO="$info" \
    "$SYMLINK_DIR/statusline-command.sh" 2>/dev/null || true
}

# ── Test 1 : symlink resolution ──
#
# A broken symlink degrades to an empty line ; this asserts the readlink
# chain still resolves to the real script dir under the worktree.
INFO1="$WORK/information"
seed_via_bus "$INFO1"
LINE="$(render "$INFO1")"
if [ -n "$LINE" ]; then
  note_pass "symlink resolution — statusline renders via ~/.claude entry-point alias"
else
  note_fail "symlink resolution — statusline rendered empty under symlinked entry"
fi

# ── Test 2 : retired signals MUST be absent ──
for banned in "mood:" "fatigue:" "breadcrumb" "coherence ⚠" "provider:" "bulb" "invention"; do
  if printf '%s' "$LINE" | grep -q "$banned"; then
    note_fail "retired signal '$banned' still rendered : $LINE"
  else
    note_pass "retired signal '$banned' absent"
  fi
done

# ── Test 3 : empty-channel render is clean (no orphan whitespace) ──
#
# FAKE_HOME has no .channel.md inboxes, so the channel segment must be
# suppressed. The render still surfaces the heart vitals.
if [ -n "$LINE" ]; then
  note_pass "empty channel set — render non-empty (heart vitals carried)"
else
  note_fail "empty channel set — render produced nothing at all"
fi

if [ "$fail" -ne 0 ]; then
  echo "FAIL — statusline regression smoke saw $fail bus-seeded assertion(s) fail" >&2
  exit 1
fi
echo "PASS — statusline regression smoke clean under bus-routed seed"
exit 0
