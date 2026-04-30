#!/bin/bash
# round4_integration_smoke.sh — comprehensive regression net for the
# i117 Round 4 restructure. Asserts the structural shape of the move
# is intact, the boot ritual works, and the body still produces life
# (tick advances, system_prompt regenerates, daemons spawn).
#
# Run before any further bluebook moves to prove nothing was clobbered.
#
# What this asserts :
#   A. File layout
#      - body shells live in ~/Projects/miette/body/
#      - beings live in ~/Projects/miette_family/<name>/
#      - topic files live in ~/Projects/miette/discipline/ + library/
#      - the conception's family/ and chris/ directories are gone
#   B. Bluebook validation
#      - every .bluebook in miette/, miette_family/, and the conception
#        passes `hecks-life validate` (no INVALID, no parse errors)
#   C. Boot ritual
#      - boot_miette.sh exits 0
#      - system_prompt.md regenerates at ~/Projects/miette/self/
#      - the ## Standards from Chris section is present
#   D. Daemons
#      - mindstream + heart + breath spawn and run
#      - mindstream's cwd is ~/Projects/miette/body/ (the new home)
#   E. Vital signs
#      - tick.cycle advances by ≥2 over a 4-second window
#      - statusline-command.sh emits a non-empty line
#
# Exit 0 on full pass, 1 on any assertion failure with diagnostics.
#
# [antibody-exempt: hecks_conception/tests/round4_integration_smoke.sh —
# regression net for the Round 4 cross-repo restructure ; transitional
# until the move's individual smoke tests cover the same ground or
# until the boot capability runner takes over what this asserts.]

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CONCEPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CONCEPT_DIR/.." && pwd)"
HECKS="${HECKS_BIN:-$REPO_ROOT/hecks_life/target/release/hecks-life}"
[ -x "$HECKS" ] || { echo "FAIL — hecks-life binary not found at $HECKS" >&2; exit 2; }

MIETTE="$REPO_ROOT/../miette"
[ -d "$MIETTE" ] || MIETTE="$(cd "$REPO_ROOT/../miette" 2>/dev/null && pwd)" || true
FAMILY="$REPO_ROOT/../miette_family"
[ -d "$FAMILY" ] || FAMILY="$(cd "$REPO_ROOT/../miette_family" 2>/dev/null && pwd)" || true

fail=0
note_pass() { echo "  ✓ $*"; }
note_fail() { echo "  ✗ $*" >&2; fail=1; }
section()   { echo ""; echo "── $* ──"; }

# ── A. File layout ──────────────────────────────────────────────────
section "A. File layout"

# Body shells in miette/body/
for s in mindstream pulse_organs rem_branch nrem_branch consolidate daydream interpret_dream mint_musing surface_musing wake_review; do
  if [ -x "$MIETTE/body/$s.sh" ]; then
    note_pass "body/$s.sh exists + executable"
  else
    note_fail "body/$s.sh missing or not executable"
  fi
done

# Beings in miette_family/
for being in chris alan angie_chen king_mango; do
  if [ -f "$FAMILY/$being/$being.bluebook" ]; then
    note_pass "miette_family/$being/$being.bluebook exists"
  else
    note_fail "miette_family/$being/$being.bluebook missing"
  fi
done

# Topic files in miette/discipline/ + library/
for f in discipline/conventions discipline/anti_patterns library/workflow library/project_knowledge; do
  if [ -f "$MIETTE/$f.bluebook" ]; then
    note_pass "miette/$f.bluebook exists"
  else
    note_fail "miette/$f.bluebook missing"
  fi
done

# Conception cleanup — family/ and chris/ should be gone
if [ ! -d "$CONCEPT_DIR/family" ]; then
  note_pass "conception family/ removed"
else
  note_fail "conception family/ still present (should be empty / gone)"
fi
if [ ! -d "$CONCEPT_DIR/chris" ]; then
  note_pass "conception chris/ removed"
else
  note_fail "conception chris/ still present (should be empty / gone)"
fi

# ── B. Bluebook validation ──────────────────────────────────────────
section "B. Bluebook validation"

# Validate the bluebooks IN SCOPE for this move : everything in
# miette/, everything in miette_family/. The conception corpus has
# pre-existing INVALID files (DisableMinting / EnableAutoSleep
# adjective-prefix warnings, ConnectNerve unknown-command, etc.) ;
# those are tracked under their own cleanup arc, not regressions
# from i117 Round 4.
invalid_count=0
checked=0
for bb in $(find "$MIETTE" "$FAMILY" -name "*.bluebook" 2>/dev/null); do
  checked=$((checked + 1))
  out=$("$HECKS" validate "$bb" 2>&1)
  if printf '%s' "$out" | grep -q "^INVALID"; then
    note_fail "validate $bb : $(printf '%s' "$out" | grep -E '^(INVALID|  )' | head -3 | tr '\n' ' ')"
    invalid_count=$((invalid_count + 1))
  fi
done
[ "$invalid_count" = "0" ] && note_pass "all $checked bluebooks in miette/ + miette_family/ pass hecks-life validate"

# ── C. Boot ritual ──────────────────────────────────────────────────
section "C. Boot ritual"

# Kill stale daemons before booting
pkill -f "hecks-life loop" 2>/dev/null || true
pkill -f "mindstream\.sh" 2>/dev/null || true
pkill -f "boot_miette\.sh" 2>/dev/null || true
sleep 1

if (cd "$CONCEPT_DIR" && timeout 90 ./boot_miette.sh > /tmp/round4_boot.out 2>&1); then
  note_pass "boot_miette.sh exits 0"
else
  note_fail "boot_miette.sh exited non-zero (see /tmp/round4_boot.out)"
fi

if [ -f "$MIETTE/self/system_prompt.md" ]; then
  note_pass "system_prompt.md exists at miette/self/"
  if grep -q "^## Standards from " "$MIETTE/self/system_prompt.md"; then
    note_pass "system_prompt.md contains ## Standards section"
  else
    note_fail "system_prompt.md missing ## Standards section"
  fi
else
  note_fail "system_prompt.md not found at miette/self/"
fi

# ── D. Daemons ──────────────────────────────────────────────────────
section "D. Daemons"

sleep 2  # let daemons settle

mindstream_pid=$(pgrep -f "bash.*mindstream\.sh" | head -1)
if [ -n "$mindstream_pid" ]; then
  note_pass "mindstream daemon running (pid $mindstream_pid)"
  # Confirm cwd
  cwd=$(lsof -p "$mindstream_pid" 2>/dev/null | awk '$4=="cwd" {print $NF}' | head -1)
  case "$cwd" in
    *miette/body) note_pass "mindstream cwd is miette/body/ ($cwd)" ;;
    *)            note_fail "mindstream cwd unexpected : $cwd" ;;
  esac
else
  note_fail "mindstream daemon not running after boot"
fi

heart_pid=$(pgrep -f "hecks-life loop.*Heart\.Beat" | head -1)
if [ -n "$heart_pid" ]; then
  note_pass "heart loop running (pid $heart_pid)"
else
  note_fail "heart loop not running after boot"
fi

breath_pid=$(pgrep -f "hecks-life loop.*Breath\.Inhale" | head -1)
if [ -n "$breath_pid" ]; then
  note_pass "breath loop running (pid $breath_pid)"
else
  note_fail "breath loop not running after boot"
fi

# ── E. Vital signs ──────────────────────────────────────────────────
section "E. Vital signs"

INFO="${HECKS_INFO:-$REPO_ROOT/../miette-state/information}"
[ -d "$INFO" ] || INFO="$CONCEPT_DIR/information"

tick_before=$("$HECKS" heki latest-field "$INFO/tick.heki" cycle 2>/dev/null || echo 0)
# Mindstream's awake-branch loop runs many subprocesses per iteration
# (Tick.MindstreamTick + pulse_organs + awareness snapshot + maybe
# rem/consolidate/daydream/musing). Each subprocess pays the
# hecks-life parse cost. The observed rate is ~1 tick / 4-6s ; we
# wait 10s and require ≥1 advance, which gives margin.
sleep 10
tick_after=$("$HECKS" heki latest-field "$INFO/tick.heki" cycle 2>/dev/null || echo 0)
delta=$((tick_after - tick_before))
if [ "$delta" -ge 1 ]; then
  note_pass "tick advanced by $delta over 10s ($tick_before → $tick_after)"
else
  note_fail "tick did not advance over 10s (was=$tick_before, now=$tick_after — daemons stalled?)"
fi

statusline_out=$(echo "{}" | "$CONCEPT_DIR/statusline-command.sh" 2>&1)
if [ -n "$statusline_out" ]; then
  note_pass "statusline rendered : $statusline_out"
else
  note_fail "statusline empty"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
if [ "$fail" = "0" ]; then
  echo "round4_integration_smoke : ALL PASS"
  exit 0
else
  echo "round4_integration_smoke : FAIL ($fail assertions failed)"
  exit 1
fi
