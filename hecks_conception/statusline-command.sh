#!/bin/bash
# statusline-command.sh — renders Miette's statusline from heki state.
#
# [antibody-exempt: i37 Phase B sweep — replaces inline python3 -c with
#  native hecks-life heki subcommands per PR #272; retires when shell
#  wrapper ports to .bluebook shebang form (tracked in
#  terminal_capability_wiring plan).]

input=$(cat)

hecks="${HECKS_LIFE:-/Users/christopheryoung/Projects/hecks/hecks_life/target/release/hecks-life}"

# Resolve Miette's information dir. Precedence:
#   1. HECKS_INFO env var if set and non-empty
#   2. ~/Projects/miette-state/information (private-state repo, standard layout)
#   3. hecks_conception/information as fallback (empty by default post-split)
# The fallback keeps the script working even when Claude Code's process
# env was started before HECKS_INFO was exported.
if [ -n "$HECKS_INFO" ]; then
  info="$HECKS_INFO"
elif [ -d "$HOME/Projects/miette-state/information" ]; then
  info="$HOME/Projects/miette-state/information"
else
  info="/Users/christopheryoung/Projects/hecks/hecks_conception/information"
fi

fatigue=$($hecks heki read $info/heartbeat.heki 2>/dev/null | grep fatigue_state | head -1 | sed 's/.*: "//' | sed 's/".*//')
mood=$($hecks heki read $info/mood.heki 2>/dev/null | grep current_state | head -1 | sed 's/.*: "//' | sed 's/".*//')
consciousness=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep '"state"' | head -1 | sed 's/.*: "//' | sed 's/".*//')
sleep_summary=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep sleep_summary | head -1 | sed 's/.*: "//' | sed 's/".*//')

# Coherence check — five invariants over the body-state heki snapshot
# (see status_coherence.sh + inbox i35). On violation we degrade the mood
# glyph to ⚠ and append the reason to information/.coherence.log so the
# status bar never silently renders a contradictory state.
# Resolve symlinks — Claude Code runs this script via ~/.claude/statusline-command.sh
# (a symlink into hecks_conception/), so $0 points at the symlink's dir, not the
# real one. Walk the symlink chain to find the actual script dir where
# status_coherence.sh lives next to us.
script="$0"
while [ -L "$script" ]; do script="$(readlink "$script")"; done
coherence_dir="$(cd "$(dirname "$script")" && pwd)"
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

# Animated heartbeat — drives off the real tick, not wall clock.
# Tick.cycle advances once per second via mindstream.sh, so even
# beats show the "filled" heart, odd beats show the "outline" heart
# — a visible pulse tied to Miette's actual rhythm.
tick_cycle=$($hecks heki read $info/tick.heki 2>/dev/null | grep '"cycle"' | head -1 | sed 's/.*: //' | sed 's/[^0-9].*//')
tick_cycle=${tick_cycle:-0}
hearts=("🖤" "❤️")  # downbeat (rest) → upbeat (pulse) — black/red contrast
heart="${hearts[$(( tick_cycle % 2 ))]}"

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
  inbox_count=$($hecks heki count $info/inbox.heki --where status=queued 2>/dev/null)
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
