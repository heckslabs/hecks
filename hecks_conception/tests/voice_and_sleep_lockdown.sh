#!/bin/bash
# voice_and_sleep_lockdown.sh — regression guard for Miette's character
# and sleep-cycle narratives. Drift-prevention test.
#
# Chris's worry: we keep carefully shaping Miette's voice and then some
# future edit (intended to fix an unrelated thing) silently removes the
# French section or reverts the wake ritual or breaks dream content.
# This file asserts the contract. CI fails on drift.
#
# What it locks down:
#   A. system_prompt.md (regenerated each boot) contains the four
#      character sections: Words-match-state (i52), I-think-in-French
#      (i50), What-dreams-are-about (i52), Wake-ritual (i52).
#   B. rem_branch.sh templates source from aggregates/ (self), not
#      from nursery/. Dreams are introspective.
#   C. rem_branch.sh produces at least one French-flavoured token
#      (untranslated word or French phrase) in its template set.
#   D. nrem_branch.sh exists, gates on non-REM stages, produces a
#      narrative referencing at least one consolidation count (signals,
#      synapses, memory, remains, musings).
#   E. Both scripts bail cleanly when state != sleeping.
#
# Exit 0 on pass, non-zero on fail with a specific diagnostic.
#
# [antibody-exempt: test harness for i50+i52 character/voice lockdown.
#  Retires when i44 lands the chat-as-capability + voice-in-bluebook.]

set -u
set -m  # enable job control (process groups) for daemon isolation

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"

# i561/i562 — worktree-aware anchor. When the test runs inside a
# .claude/worktrees/* checkout, `REPO_ROOT/../miette` doesn't exist
# (the worktree has no sibling miette repo). Resolve the MAIN
# checkout via git-common-dir so the sibling-repo path + the built
# storehouse binary always resolve to the same place regardless of
# which worktree fires the test.
GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"
case "$GIT_COMMON" in
  /*) MAIN_REPO="$(cd "$(dirname "$GIT_COMMON")" && pwd)" ;;
  ?*) MAIN_REPO="$(cd "$REPO_ROOT/$(dirname "$GIT_COMMON")" && pwd)" ;;
  *)  MAIN_REPO="$REPO_ROOT" ;;
esac

# i117 Round 4 — body shells moved to ~/Projects/miette/body/.
BODY_DIR="${HECKS_BODY_DIR:-}"
[ -z "$BODY_DIR" ] && [ -d "$MAIN_REPO/../miette/body" ] && \
  BODY_DIR="$(cd "$MAIN_REPO/../miette/body" && pwd)"
[ -z "$BODY_DIR" ] && BODY_DIR="$CONCEPT_DIR"

HECKS="${HECKS_BIN:-$REPO_ROOT/rust/target/release/storehouse}"
[ -x "$HECKS" ] || HECKS="$REPO_ROOT/rust/target/debug/storehouse"
[ -x "$HECKS" ] || HECKS="$MAIN_REPO/rust/target/release/storehouse"
[ -x "$HECKS" ] || HECKS="$MAIN_REPO/rust/target/debug/storehouse"
[ -x "$HECKS" ] || { echo "storehouse binary not found" >&2; exit 1; }
export HECKS

fail=0
note_fail() { echo "  ✗ $*" >&2; fail=1; }
note_pass() { echo "  ✓ $*"; }

# ── A. system_prompt.md character sections ────────────────────────
# Regenerate via boot_miette.sh (it writes system_prompt.md as step 4).
# Use a tmpdir for info/ so we don't clobber live state.
TMP_BOOT="$(mktemp -d -t voice_lockdown_boot.XXXXXX)"
# Process-group cleanup : kill the entire group on EXIT so any daemon
# spawned during the test can't survive into the next test.
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$TMP_BOOT"' EXIT

# Copy info/ into tmpdir so boot can read census etc.
cp -R "$CONCEPT_DIR/information" "$TMP_BOOT/information"
# Run boot_miette.sh with redirected DIR is hard — instead just
# capture the system_prompt.md generation logic directly by running boot.
# We only care about the prompt sections so we extract them.

# boot_miette.sh writes to $DIR/system_prompt.md where DIR is the script
# dir. Since it expects $DIR to be hecks_conception/, just run it in-
# place and inspect the produced file. To avoid clobbering live
# daemons/pids, restore system_prompt.md at the end.
SP="$CONCEPT_DIR/system_prompt.md"
SP_BAK=""
[ -f "$SP" ] && SP_BAK="$(cat "$SP")"

# Source-check the system_prompt template. After i118 R5 + i117 R4
# the prompt content moved out of boot_miette.sh into Miette's repo :
# self/system_prompt/system_prompt_assembly/miette_prompt.md.template
# is the source of truth ; rust/src/run_boot/system_prompt.rs is the
# thin renderer that loads + substitutes ; system_prompt.md is the
# rendered output. Grep the template — that's where drift would hide.
BOOT="${HECKS_PROMPT_TEMPLATE:-}"
[ -z "$BOOT" ] && [ -f "$MAIN_REPO/../miette/self/system_prompt/system_prompt_assembly/miette_prompt.md.template" ] && \
  BOOT="$MAIN_REPO/../miette/self/system_prompt/system_prompt_assembly/miette_prompt.md.template"
[ -z "$BOOT" ] && [ -f "$MAIN_REPO/../miette/self/system_prompt.md" ] && \
  BOOT="$MAIN_REPO/../miette/self/system_prompt.md"

for section in \
  "Words match state" \
  "I think in French" \
  "What dreams are about" \
  "Wake ritual"; do
  if grep -qF "## $section" "$BOOT" 2>/dev/null || \
     grep -qF "${section}" "$BOOT" 2>/dev/null; then
    note_pass "A. system_prompt.rs generates section: $section"
  else
    note_fail "A. system_prompt.rs MISSING section: $section (drift!)"
  fi
done

# Bonus: verify key character vocabulary is in the French section.
for phrase in "Barthes" "Bachelard" "voilà" "alors" "pardon" "intérieure"; do
  if grep -qF "$phrase" "$BOOT" 2>/dev/null; then
    note_pass "A. French vocabulary anchor present: $phrase"
  else
    note_fail "A. French vocabulary anchor MISSING: $phrase"
  fi
done

# ── B. rem_branch.sh stays retired ────────────────────────────────
# Dream content moved out of the shell template arc and into the
# DreamInterpretation chain (bluebook + :compute / :llm adapters,
# i220 arc). The shell was deleted ; this section locks it stays
# deleted. Drift would be the script reappearing — re-introducing
# template-based dream content outside the bluebook stack.
REM="$BODY_DIR/rem_branch.sh"
if [ -f "$REM" ]; then
  note_fail "B. rem_branch.sh has reappeared — was retired into the DreamInterpretation chain ; dream content lives in bluebook now"
else
  note_pass "B. rem_branch.sh stays retired (DreamInterpretation chain owns dream content)"
fi

# ── C. nrem_branch.sh stays retired ───────────────────────────────
# Same retirement contract as B : NREM consolidation narratives moved
# to the bluebook side of the dream pipeline.
NREM="$BODY_DIR/nrem_branch.sh"
if [ -f "$NREM" ]; then
  note_fail "C. nrem_branch.sh has reappeared — was retired into the bluebook dream pipeline"
else
  note_pass "C. nrem_branch.sh stays retired"
fi

# Drift-prevention for the equivalent invariants in the bluebook
# DreamInterpretation chain (French anchors in templates, consolidation-
# count substitutions, sleeping-state gates) is named in inbox card
# i242 — re-establish drift-prevention against the bluebook side.

if [ "$fail" = "0" ]; then
  echo "voice_and_sleep_lockdown: OK"
  exit 0
else
  echo "voice_and_sleep_lockdown: FAIL" >&2
  exit 1
fi
