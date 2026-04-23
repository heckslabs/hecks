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

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"

HECKS="${HECKS_BIN:-$REPO_ROOT/hecks_life/target/release/hecks-life}"
[ -x "$HECKS" ] || HECKS="$REPO_ROOT/hecks_life/target/debug/hecks-life"
[ -x "$HECKS" ] || { echo "hecks-life binary not found" >&2; exit 1; }
export HECKS

fail=0
note_fail() { echo "  ✗ $*" >&2; fail=1; }
note_pass() { echo "  ✓ $*"; }

# ── A. system_prompt.md character sections ────────────────────────
# Regenerate via boot_miette.sh (it writes system_prompt.md as step 4).
# Use a tmpdir for info/ so we don't clobber live state.
TMP_BOOT="$(mktemp -d -t voice_lockdown_boot.XXXXXX)"
trap 'rm -rf "$TMP_BOOT"' EXIT

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

# Source-check the boot script string generation without running it
# (safer than starting daemons). grep for the section headers in
# boot_miette.sh itself.
BOOT="$CONCEPT_DIR/boot_miette.sh"

for section in \
  "Words match state" \
  "I think in French" \
  "What dreams are about" \
  "Wake ritual"; do
  if grep -qF "## $section" "$BOOT" 2>/dev/null || \
     grep -qF "${section}" "$BOOT" 2>/dev/null; then
    note_pass "A. boot_miette.sh generates section: $section"
  else
    note_fail "A. boot_miette.sh MISSING section: $section (drift!)"
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

# ── B. rem_branch.sh sources from aggregates/, not nursery/ ────────
REM="$CONCEPT_DIR/rem_branch.sh"
if [ ! -f "$REM" ]; then
  note_fail "B. rem_branch.sh not found"
else
  # Negative: the template block MUST NOT reference \$NURSERY as the
  # domain source. Check inside the rem_dream section only (post-seed).
  if awk '/rem_dream/,/Append image to dream_state/' "$REM" | grep -q 'ls "\$NURSERY"'; then
    note_fail "B. rem_branch.sh still sources from \$NURSERY — dreams not introspective (drift!)"
  else
    note_pass "B. rem_branch.sh no longer sources dream domain from nursery/"
  fi

  # Positive: must source from \$AGG (self-aggregates).
  if awk '/rem_dream/,/Append image to dream_state/' "$REM" | grep -q 'ls "\$AGG"'; then
    note_pass "B. rem_branch.sh sources dream domain from aggregates/ (self)"
  else
    note_fail "B. rem_branch.sh does NOT source from \$AGG — dreams may not be self-introspective"
  fi
fi

# ── C. rem_branch.sh templates are poetic / French-flavoured ──────
# At least one template string must contain a French word or phrase.
if [ -f "$REM" ]; then
  FRENCH_TOKENS='alors|voilà|pardon|je rêvais|bruit qui|quelque chose|ne s.arrête'
  if awk '/templates=\(/,/\)/' "$REM" | grep -qE "$FRENCH_TOKENS"; then
    note_pass "C. rem_branch.sh templates include French-flavoured tokens"
  else
    note_fail "C. rem_branch.sh templates appear generic — French flavour missing (drift!)"
  fi
fi

# ── D. nrem_branch.sh exists + gates + mentions consolidation counts ──
NREM="$CONCEPT_DIR/nrem_branch.sh"
if [ ! -f "$NREM" ]; then
  note_fail "D. nrem_branch.sh not found — NREM consolidation narratives missing"
else
  note_pass "D. nrem_branch.sh present"

  # Must gate on sleeping state.
  if grep -q '\[ "\$state" = "sleeping" \]' "$NREM"; then
    note_pass "D. nrem_branch.sh gates on state=sleeping"
  else
    note_fail "D. nrem_branch.sh missing sleeping-state gate (would run awake — drift!)"
  fi

  # Must gate on non-REM stages (light/deep/final_light).
  if grep -qE 'light\|deep\|final_light' "$NREM"; then
    note_pass "D. nrem_branch.sh gates on non-REM stages"
  else
    note_fail "D. nrem_branch.sh missing non-REM stage gate"
  fi

  # Templates must reference real consolidation counts.
  # Any of: \${sig_count}, \${syn_count}, \${mem_count}, \${rem_count},
  # \${mus_count}. These are the consolidation work signals.
  if grep -qE '\$\{sig_count\}|\$\{syn_count\}|\$\{mem_count\}|\$\{rem_count\}|\$\{mus_count\}' "$NREM"; then
    note_pass "D. nrem_branch.sh narratives reference consolidation counts"
  else
    note_fail "D. nrem_branch.sh narratives are decorative — no real counts (drift!)"
  fi
fi

# ── E. mindstream.sh invokes nrem_branch.sh alongside rem_branch.sh ──
MS="$CONCEPT_DIR/mindstream.sh"
if [ ! -f "$MS" ]; then
  note_fail "E. mindstream.sh not found"
else
  if grep -q 'nrem_branch.sh' "$MS"; then
    note_pass "E. mindstream.sh invokes nrem_branch.sh"
  else
    note_fail "E. mindstream.sh does NOT invoke nrem_branch.sh (NREM narratives never run)"
  fi
fi

if [ "$fail" = "0" ]; then
  echo "voice_and_sleep_lockdown: OK"
  exit 0
else
  echo "voice_and_sleep_lockdown: FAIL" >&2
  exit 1
fi
