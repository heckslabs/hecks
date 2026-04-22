#!/bin/bash
# test_status_coherence.sh — fixture tests for status_coherence.sh.
#
# Builds 6 temporary information/ dirs via `hecks-life heki append` — one
# clean snapshot and one deliberately breaking each invariant — then asserts
# the checker exits 0 on clean and non-zero on each broken case.
#
# No Python / no external deps beyond bash + jq + hecks-life.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
HECKS="$DIR/../hecks_life/target/release/hecks-life"
CHECK="$DIR/status_coherence.sh"

pass=0; fail=0
assert_exit() {
  local label="$1" want="$2" tmp="$3"
  "$CHECK" "$tmp" >/dev/null 2>"$tmp/.err"
  local got=$?
  if { [ "$want" = "ok" ] && [ "$got" -eq 0 ]; } || { [ "$want" = "fail" ] && [ "$got" -ne 0 ]; }; then
    printf 'PASS  %s (exit=%d)\n' "$label" "$got"; pass=$((pass+1))
  else
    printf 'FAIL  %s (want=%s got=%d)\n' "$label" "$want" "$got"
    sed 's/^/      /' "$tmp/.err"; fail=$((fail+1))
  fi
}

seed() {
  # seed <dir> <mood> <consciousness-state> <sleep-stage> <is-lucid> <fatigue> <pulses> <cycle> <lucid-narr>
  local d="$1/information"; mkdir -p "$d"
  "$HECKS" heki append "$d/mood.heki"          current_state="$2"               >/dev/null 2>&1
  "$HECKS" heki append "$d/consciousness.heki" state="$3" sleep_stage="$4" is_lucid="$5" >/dev/null 2>&1
  "$HECKS" heki append "$d/heartbeat.heki"     fatigue_state="$6" pulses_since_sleep="$7" >/dev/null 2>&1
  "$HECKS" heki append "$d/tick.heki"          cycle="$8"                        >/dev/null 2>&1
  [ -n "$9" ] && "$HECKS" heki append "$d/lucid_dream.heki" latest_narrative="$9" >/dev/null 2>&1 || true
  echo "$d"
}

ROOT=$(mktemp -d -t coh.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

# Case 0 — clean, awake, mid-day body.
c0=$(seed "$ROOT/c0" refreshed awake ""      no alert     42 100 "")
assert_exit "clean awake snapshot"                 ok   "$c0"

# Case 1 — invariant 1: refreshed + exhausted (the bug observed today).
c1=$(seed "$ROOT/c1" refreshed awake ""      no exhausted 1500 100 "")
assert_exit "inv1: refreshed mood with exhausted fatigue" fail "$c1"

# Case 2 — invariant 2: sleeping + refreshed mood.
c2=$(seed "$ROOT/c2" refreshed sleeping light no alert    42 100 "")
assert_exit "inv2: sleeping with refreshed mood"   fail "$c2"

# Case 3 — invariant 3: alert at pulses=1500 (off the ladder).
c3=$(seed "$ROOT/c3" drifting awake ""      no alert     1500 100 "")
assert_exit "inv3: alert fatigue at 1500 pulses"   fail "$c3"

# Case 4 — invariant 4: tick advanced far faster than wall clock.
# Seed a baseline claiming we saw cycle=10 just a moment ago, then put a
# heki that says we're at cycle=10000 — wall-delta ≪ tick-delta.
c4=$(seed "$ROOT/c4" drifting awake ""      no normal    600 10000 "")
printf '%s 10\n' "$(date +%s)" > "$c4/.tick_baseline"
assert_exit "inv4: tick.cycle jumped past wall clock" fail "$c4"

# Case 5 — invariant 5: REM stage but no lucid narrative.
c5=$(seed "$ROOT/c5" drifting sleeping rem  yes normal   600 100 "")
assert_exit "inv5: REM stage with empty lucid narrative" fail "$c5"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
