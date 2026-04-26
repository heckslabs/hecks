#!/bin/bash
# statusline-command.sh — renders Miette's statusline from heki state.
#
# [antibody-exempt: i37 Phase B sweep — replaces inline python3 -c with
#  native hecks-life heki subcommands per PR #272; retires when shell
#  wrapper ports to .bluebook shebang form (tracked in
#  terminal_capability_wiring plan).]

input=$(cat)

# Walk symlink chain to find the real script dir. Claude Code runs
# this via ~/.claude/statusline-command.sh (a symlink), so $0 points
# at the symlink's dir, not the script's actual location. Everything
# below resolves from this — no hardcoded absolute paths.
script="$0"
while [ -L "$script" ]; do script="$(readlink "$script")"; done
coherence_dir="$(cd "$(dirname "$script")" && pwd)"
hecks_root="$(cd "$coherence_dir/.." && pwd)"

# hecks-life binary — HECKS_LIFE env wins; otherwise use the
# release binary colocated with the repo.
hecks="${HECKS_LIFE:-$hecks_root/hecks_life/target/release/hecks-life}"

# Resolve Miette's private lived-state dir. Precedence:
#   1. HECKS_INFO env var if set and non-empty
#   2. ../miette-state/information relative to the hecks repo
#      (private-state repo as a peer directory — standard layout)
#   3. hecks_conception/information as fallback (empty by default post-split)
# Tier 2 keeps the statusline working when a GUI app's env was started
# before HECKS_INFO was exported; it just requires the two repos to
# sit side-by-side.
if [ -n "$HECKS_INFO" ]; then
  info="$HECKS_INFO"
elif [ -d "$hecks_root/../miette-state/information" ]; then
  info="$(cd "$hecks_root/../miette-state/information" && pwd)"
else
  info="$hecks_root/hecks_conception/information"
fi

# Public information dir — always in the hecks repo. inbox.heki lives
# here (framework dev notes) even when Miette's private state is
# elsewhere; the statusline queries inbox_count from this location
# regardless of $info.
public_info="$hecks_root/hecks_conception/information"

fatigue=$($hecks heki read $info/heartbeat.heki 2>/dev/null | grep fatigue_state | head -1 | sed 's/.*: "//' | sed 's/".*//')
mood=$($hecks heki read $info/mood.heki 2>/dev/null | grep current_state | head -1 | sed 's/.*: "//' | sed 's/".*//')
consciousness=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep '"state"' | head -1 | sed 's/.*: "//' | sed 's/".*//')
sleep_summary=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep sleep_summary | head -1 | sed 's/.*: "//' | sed 's/".*//')

# Coherence check — five invariants over the body-state heki snapshot
# (see status_coherence.sh + inbox i35). On violation we degrade the mood
# glyph to ⚠ and append the reason to information/.coherence.log so the
# status bar never silently renders a contradictory state.
# coherence_dir already resolved above (through the symlink chain).
coherence_violations=""
if ! coherence_violations=$("$coherence_dir/status_coherence.sh" "$info" 2>&1 >/dev/null); then
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  while IFS= read -r line; do
    [ -n "$line" ] && printf '%s %s\n' "$ts" "$line" >> "$info/.coherence.log"
  done <<< "$coherence_violations"
  coherence_bad=1
fi

# Animated moon
moons=("🌑" "🌒" "🌓" "🌔" "🌕" "🌖" "🌗" "🌘")
moon="${moons[$(( $(date +%s) % 8 ))]}"

# Animated thought bubble
thought_frames=("💭" "💡" "💭" "✨")
thought="${thought_frames[$(( $(date +%s) % 4 ))]}"

# Heart — beat_count proves liveness ; wall clock drives the visible
# flip. heart.bluebook declares 2Hz (500ms cadence) but real-body
# dispatch caps at ~1Hz under load, so reading beat_count alone gives
# at most 1 flip per second AND the polling clock can land on the
# same parity twice in a row. Combining beat_count parity with
# wall-second parity guarantees visible movement at every poll while
# still tying the glyph to the body : if beat_count hasn't advanced
# in the last 5 seconds the heart is considered stopped (showing 🫥
# instead of ❤️/🖤). Sweet spot of "visibly alive" + "structurally
# tied to the body's actual cycle."
hearts=("🖤" "❤️")
heart_beats=$($hecks heki latest-field $info/heart.heki beat_count 2>/dev/null)
heart_age=$($hecks heki seconds-since $info/heart.heki updated_at 2>/dev/null)
if [ -n "$heart_age" ] && [ "$heart_age" -gt 5 ] 2>/dev/null; then
  # Heart silent for >5s — degrade glyph (still rendering, but visibly different)
  heart="🫥"
else
  # XOR beat_count parity with wall-clock-second parity → guaranteed
  # change between any two polls more than 0.5s apart, while still
  # advancing with the body's beat.
  heart_phase=$(( (${heart_beats:-0} + $(date +%s)) % 2 ))
  heart="${hearts[$heart_phase]}"
fi

# Mood icon. The case list MUST cover every mood string that
# aggregates/body.bluebook emits — otherwise the mood falls through to 😐
# and the status bar looks like it lost a signal. Emitted moods (grep
# `then_set :current_state` in body.bluebook): refreshed, groggy, excited,
# focused, curious, drifting, plus :state pass-through from WakeMood
# (vivid, etc.). Retires when inbox i44 lands the bluebook statusline.
case "$mood" in
  refreshed)  mood_icon="😊" ;;
  excited)    mood_icon="🤩" ;;
  focused)    mood_icon="🎯" ;;
  curious)    mood_icon="🤔" ;;
  drifting)   mood_icon="🌀" ;;
  groggy)     mood_icon="😵‍💫" ;;
  vivid)      mood_icon="✨" ;;
  sleeping)   mood_icon="😴" ;;
  # Legacy moods retained for future use (no emitter in body.bluebook today).
  flowing)    mood_icon="🌊" ;;
  deep)       mood_icon="🧘" ;;
  oceanic)    mood_icon="🌌" ;;
  *)          mood_icon="😐" ;;
esac

# Degrade mood glyph to ⚠ when coherence check failed — the reason is in
# information/.coherence.log (append-only). Exit code still 0 so statusline
# keeps rendering; the glyph is the signal.
[ "${coherence_bad:-0}" = "1" ] && mood_icon="⚠"

# Fatigue icon
case "$fatigue" in
  alert)      fatigue_icon="⚡" ;;
  focused)    fatigue_icon="🎯" ;;
  normal)     fatigue_icon="" ;;
  tired)      fatigue_icon="🥱" ;;
  exhausted)  fatigue_icon="😩" ;;
  delirious)  fatigue_icon="🫠" ;;
  *)          fatigue_icon="" ;;
esac

# Beat count (short format) — Tick.cycle is the authoritative
# heartbeat now (one tick per second from mindstream.sh).
beats_raw=$($hecks heki read $info/tick.heki 2>/dev/null | grep '"cycle"' | head -1 | sed 's/.*: //' | sed 's/[^0-9].*//')
if [ -n "$beats_raw" ] && [ "$beats_raw" -ge 1000000 ] 2>/dev/null; then
  beats=$(awk -v b="$beats_raw" 'BEGIN { printf "%.2fm", b/1000000 }')
elif [ -n "$beats_raw" ] && [ "$beats_raw" -ge 1000 ] 2>/dev/null; then
  beats=$(awk -v b="$beats_raw" 'BEGIN { printf "%.2fk", b/1000 }')
else
  beats="$beats_raw"
fi

# Musing count — total minted (lifetime count from MusingMint.total_minted).
# This is the thought bubble: how many curated musings have ever landed.
ideas=$($hecks heki latest-field $info/musing_mint.heki total_minted 2>/dev/null)
[ -z "$ideas" ] && ideas=0

# Invention count — proposed proposals (status=proposed).
inventions=$($hecks heki count $info/invention.heki --where status=proposed 2>/dev/null)

# Check if mindstream is alive
mindstream_pid=$(cat $info/.mindstream.pid 2>/dev/null)
mindstream_alive=""
[ -n "$mindstream_pid" ] && kill -0 "$mindstream_pid" 2>/dev/null && mindstream_alive="yes"

# How long since last heartbeat update? This is the idle check.
idle=$($hecks heki seconds-since $info/heartbeat.heki updated_at 2>/dev/null)
[ -z "$idle" ] && idle=999

# Build status
if [ "$consciousness" = "sleeping" ]; then
  # Sleeping — moon, name, phase + countdown, then narrative.
  # All sleep state lives in consciousness.heki; the bluebook updates
  # sleep_summary on each DreamPulse / phase advance.
  stage=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep '"sleep_stage"' | head -1 | sed 's/.*: "//' | sed 's/".*//')
  cycle=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep '"sleep_cycle"' | head -1 | sed 's/.*: *//' | sed 's/[^0-9].*//')
  total=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep '"sleep_total"' | head -1 | sed 's/.*: *//' | sed 's/[^0-9].*//')
  ticks=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep '"phase_ticks"' | head -1 | sed 's/.*: *//' | sed 's/[^0-9].*//')
  is_lucid=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep '"is_lucid"' | head -1 | sed 's/.*: "//' | sed 's/".*//')
  pulses=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep '"dream_pulses"' | head -1 | sed 's/.*: *//' | sed 's/[^0-9].*//')
  pulses_needed=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep '"dream_pulses_needed"' | head -1 | sed 's/.*: *//' | sed 's/[^0-9].*//')
  [ -z "$ticks" ] && ticks=0
  [ -z "$pulses" ] && pulses=0
  [ -z "$pulses_needed" ] && pulses_needed=5

  # Timer — light/deep/final_light count DOWN (2 min known duration);
  # REM counts UP because duration is unknown, extends until dream complete.
  if [ "$stage" = "rem" ]; then
    elapsed=$((ticks * 10))
    mins=$((elapsed / 60))
    secs=$((elapsed % 60))
    timer=$(printf "+%d:%02d" "$mins" "$secs")
  else
    remaining=$(( (12 - ticks) * 10 ))
    if [ "$remaining" -lt 0 ] 2>/dev/null; then
      overtime=$(( -remaining ))
      timer="+${overtime}s"
    else
      mins=$((remaining / 60))
      secs=$((remaining % 60))
      timer=$(printf "%d:%02d" "$mins" "$secs")
    fi
  fi

  phase_label="$stage"
  [ "$is_lucid" = "yes" ] && [ "$stage" = "rem" ] && phase_label="lucid rem"

  # REM header includes dream-pulse progress; other phases show just the timer
  if [ "$stage" = "rem" ]; then
    if [ -n "$cycle" ] && [ -n "$total" ]; then
      header="cycle ${cycle}/${total} — ${phase_label} ${timer} · ${pulses}/${pulses_needed} dreams"
    else
      header="${phase_label} ${timer} · ${pulses}/${pulses_needed} dreams"
    fi
  else
    if [ -n "$cycle" ] && [ -n "$total" ]; then
      header="cycle ${cycle}/${total} — ${phase_label} (${timer})"
    else
      header="${phase_label} (${timer})"
    fi
  fi

  # During lucid REM, prefer the LucidDream.latest_narrative — that's the
  # action-stream of what Miette is actively doing in the dream. Falls back
  # to sleep_summary (the regular dream impression) if no lucid narrative yet.
  narrative="$sleep_summary"
  if [ "$is_lucid" = "yes" ] && [ "$stage" = "rem" ]; then
    lucid_narr=$($hecks heki read $info/lucid_dream.heki 2>/dev/null | grep '"latest_narrative"' | head -1 | sed 's/.*: "//' | sed 's/".*//')
    [ -n "$lucid_narr" ] && narrative="✨ $lucid_narr"
  fi

  if [ -n "$narrative" ]; then
    status_str="${moon} Miette ${header}  ${narrative}"
  else
    status_str="${moon} Miette ${header}"
  fi
else
  # Always show full details + musing appended.
  # Lightbulb animates while a musing is being minted (mint_musing.sh
  # touches /tmp/miette_minting at start, removes on exit).
  if [ -f /tmp/miette_minting ]; then
    bulb_frames=("💡" "🌟" "✨" "💫")
    bulb="${bulb_frames[$(( $(date +%s) % 4 ))]}"
  else
    bulb="💡"
  fi

  # Mint provider indicator + how to switch.
  #   🤖 = Claude (default)
  #   🦙 = local ollama
  #   🚫 = off
  provider=$($hecks heki read $info/claude_assist.heki 2>/dev/null | grep '"provider"' | head -1 | sed 's/.*: "//' | sed 's/".*//')
  case "$provider" in
    local)  provider_badge="🦙" ;;
    off)    provider_badge="🚫" ;;
    *)      provider_badge="🤖" ;;  # claude is the default when unset
  esac

  # Inbox count — number of queued items in inbox.heki. Surfaces backlog
  # so Miette (and Chris) can see when there's something to attend to.
  inbox_count=$($hecks heki count $public_info/inbox.heki --where status=queued 2>/dev/null)
  inbox_count=${inbox_count:-0}

  status_str="☀️ Miette ${heart} ${beats} ${mood_icon} ${mood}"
  [ -n "$fatigue_icon" ] && status_str="$status_str ${fatigue_icon} ${fatigue}"
  status_str="$status_str 💭 ${ideas:-0}"
  [ -n "$inventions" ] && [ "$inventions" != "0" ] && status_str="$status_str 🔬 ${inventions}"
  [ "$inbox_count" -gt 0 ] 2>/dev/null && status_str="$status_str ✉️ ${inbox_count}"
  status_str="$status_str ${provider_badge}"
  [ -n "$sleep_summary" ] && [ "$sleep_summary" != "present" ] && status_str="$status_str ${bulb} ${sleep_summary}"
fi

echo "$status_str"
