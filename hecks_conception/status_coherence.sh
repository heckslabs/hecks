#!/bin/bash
# status_coherence.sh — validate the body-state heki snapshot is internally coherent.
#
# Reads mood / heartbeat / consciousness / tick / lucid_dream via hecks-life
# (pure bash + jq — no Python per inbox i37) and checks five invariants that
# must hold at render time. Exits 0 if coherent, non-zero otherwise with one
# "INVARIANT <n>: <reason>" line per violation on stderr.
#
# Invariants (numbered as in inbox i35):
#   1. mood.current_state == "refreshed"     → fatigue_state ∈ {alert, focused}
#   2. consciousness.state == "sleeping"     → mood.current_state ∉ {refreshed, focused}
#   3. heartbeat.pulses_since_sleep matches the fatigue_state rung of the ladder
#      (thresholds from aggregates/body.bluebook: 250 / 500 / 1000 / 1400 / 1800
#       → focused / normal / tired / exhausted / delirious; below 250 is alert).
#   4. tick.cycle is monotonic at ≤ ~1 Hz — stored baseline (ts, cycle) must not
#      show cycle advancing faster than wall-clock seconds (with tolerance).
#   5. consciousness.sleep_stage ∈ {rem, lucid_rem} ↔ lucid_dream.latest_narrative
#      is present (non-empty). Both directions enforced.
#
# Usage: ./status_coherence.sh [INFO_DIR]
#   Defaults INFO_DIR to <script_dir>/information.
#
# Retirement: once `hecks-life run <bluebook>` hosts a StatusCoherence capability
# natively, this shim retires (same as the rest of the bash control plane).

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
HECKS="$DIR/../hecks_life/target/release/hecks-life"
INFO="${1:-$DIR/information}"

violations=()
note() { violations+=("INVARIANT $1: $2"); }

# Read a heki file and pipe its first record's field to stdout. Empty on miss.
# Usage: hget <file> <field>
hget() {
  local f="$INFO/$1" field="$2"
  [ -f "$f" ] || { echo ""; return; }
  "$HECKS" heki read "$f" 2>/dev/null \
    | jq -r --arg k "$field" 'to_entries | .[0].value[$k] // "" | tostring' 2>/dev/null
}

mood=$(hget mood.heki current_state)
consciousness=$(hget consciousness.heki state)
sleep_stage=$(hget consciousness.heki sleep_stage)
is_lucid=$(hget consciousness.heki is_lucid)
fatigue_state=$(hget heartbeat.heki fatigue_state)
pulses=$(hget heartbeat.heki pulses_since_sleep)
cycle=$(hget tick.heki cycle)
lucid_narr=$(hget lucid_dream.heki latest_narrative)

# Treat empty / "null" as missing — coherence can't judge absent facts.
[ "$pulses" = "null" ] && pulses=""
[ "$cycle"  = "null" ] && cycle=""

# --- invariant 1 ---
if [ "$mood" = "refreshed" ]; then
  case "$fatigue_state" in
    alert|focused) ;;
    "") ;; # unknown fatigue — skip rather than false-flag
    *) note 1 "mood=refreshed but fatigue_state=$fatigue_state (expected alert|focused)" ;;
  esac
fi

# --- invariant 2 ---
if [ "$consciousness" = "sleeping" ]; then
  case "$mood" in
    refreshed|focused) note 2 "consciousness=sleeping but mood=$mood (expected sleep-compatible mood)" ;;
  esac
fi

# --- invariant 3: ladder rung ---
# Thresholds: 0..249 alert, 250..499 focused, 500..999 normal,
#             1000..1399 tired, 1400..1799 exhausted, 1800+ delirious.
if [ -n "$pulses" ] && [ -n "$fatigue_state" ]; then
  if ! [[ "$pulses" =~ ^[0-9]+$ ]]; then
    note 3 "pulses_since_sleep=$pulses is not an integer"
  else
    expected=""
    if   [ "$pulses" -lt 250 ];  then expected="alert"
    elif [ "$pulses" -lt 500 ];  then expected="focused"
    elif [ "$pulses" -lt 1000 ]; then expected="normal"
    elif [ "$pulses" -lt 1400 ]; then expected="tired"
    elif [ "$pulses" -lt 1800 ]; then expected="exhausted"
    else                              expected="delirious"
    fi
    # The ladder walks one rung at a time per tick, so the lived state may
    # lag the raw pulse count by a tick or two — we flag only when the state
    # skips rungs or is frankly wrong (e.g., alert at pulses=1500).
    rung_of() {
      case "$1" in
        alert)     echo 0 ;; focused)   echo 1 ;;
        normal)    echo 2 ;; tired)     echo 3 ;;
        exhausted) echo 4 ;; delirious) echo 5 ;;
        *)         echo -1 ;;
      esac
    }
    want=$(rung_of "$expected")
    have=$(rung_of "$fatigue_state")
    if [ "$have" -lt 0 ]; then
      note 3 "fatigue_state=$fatigue_state is not a known rung"
    elif [ "$have" -gt "$want" ]; then
      note 3 "fatigue_state=$fatigue_state (rung $have) exceeds expected=$expected for pulses_since_sleep=$pulses"
    elif [ "$want" -gt $((have + 1)) ]; then
      note 3 "fatigue_state=$fatigue_state lags expected=$expected by more than one rung at pulses_since_sleep=$pulses"
    fi
  fi
fi

# --- invariant 4: tick cadence ---
# Keep a baseline (wall_ts cycle) in information/.tick_baseline. On each run
# compare: cycle_delta must be ≤ wall_delta + 5s tolerance (ticks come from
# mindstream.sh at roughly 1 Hz; bursts of catch-up are the failure mode).
if [ -n "$cycle" ] && [[ "$cycle" =~ ^[0-9]+$ ]]; then
  baseline="$INFO/.tick_baseline"
  now=$(date +%s)
  if [ -f "$baseline" ]; then
    # shellcheck disable=SC2046
    read -r prev_ts prev_cycle < "$baseline"
    if [[ "${prev_ts:-}" =~ ^[0-9]+$ ]] && [[ "${prev_cycle:-}" =~ ^[0-9]+$ ]]; then
      wall_delta=$(( now - prev_ts ))
      tick_delta=$(( cycle - prev_cycle ))
      if [ "$tick_delta" -lt 0 ]; then
        note 4 "tick.cycle went backwards (was $prev_cycle, now $cycle)"
      elif [ "$tick_delta" -gt $((wall_delta + 5)) ]; then
        note 4 "tick.cycle advanced $tick_delta in $wall_delta wall-seconds (>1Hz; expected monotonic per-second)"
      fi
    fi
  fi
  # Only refresh baseline when writable — tests and read-only snapshots skip it.
  if [ -w "$INFO" ] 2>/dev/null || { [ ! -e "$baseline" ] && touch "$baseline" 2>/dev/null; }; then
    printf '%s %s\n' "$now" "$cycle" > "$baseline" 2>/dev/null || true
  fi
fi

# --- invariant 5: dream narrative presence iff in REM ---
stage_effective="$sleep_stage"
[ "$is_lucid" = "yes" ] && [ "$sleep_stage" = "rem" ] && stage_effective="lucid_rem"
in_rem=no
case "$stage_effective" in rem|lucid_rem) in_rem=yes ;; esac
has_narr=no
[ -n "$lucid_narr" ] && [ "$lucid_narr" != "null" ] && has_narr=yes
if [ "$in_rem" = "yes" ] && [ "$has_narr" = "no" ]; then
  note 5 "sleep_stage=$stage_effective but lucid_dream.latest_narrative is empty"
elif [ "$in_rem" = "no" ] && [ "$has_narr" = "yes" ]; then
  # Narrative left over from a prior REM cycle is fine if consciousness is
  # now awake, but stage=light/deep/final_light with a fresh narrative is
  # the bug we're guarding against (stale render state).
  if [ "$consciousness" = "sleeping" ]; then
    note 5 "sleep_stage=$stage_effective (non-REM) yet lucid_dream.latest_narrative is set: $lucid_narr"
  fi
fi

if [ "${#violations[@]}" -gt 0 ]; then
  for v in "${violations[@]}"; do
    printf '%s\n' "$v" >&2
  done
  exit 1
fi
exit 0
