#!/bin/bash

input=$(cat)

hecks=/Users/christopheryoung/Projects/hecks/hecks_life/target/release/hecks-life
info=/Users/christopheryoung/Projects/hecks/hecks_conception/information

fatigue=$($hecks heki read $info/heartbeat.heki 2>/dev/null | grep fatigue_state | head -1 | sed 's/.*: "//' | sed 's/".*//')
mood=$($hecks heki read $info/mood.heki 2>/dev/null | grep current_state | head -1 | sed 's/.*: "//' | sed 's/".*//')
consciousness=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep '"state"' | head -1 | sed 's/.*: "//' | sed 's/".*//')
sleep_summary=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep sleep_summary | head -1 | sed 's/.*: "//' | sed 's/".*//')

# Animated moon
moons=("🌑" "🌒" "🌓" "🌔" "🌕" "🌖" "🌗" "🌘")
moon="${moons[$(( $(date +%s) % 8 ))]}"

# Animated thought bubble
thought_frames=("💭" "💡" "💭" "✨")
thought="${thought_frames[$(( $(date +%s) % 4 ))]}"

# Animated heartbeat
hearts=("🩷" "❤️")
heart="${hearts[$(( $(date +%s) % 2 ))]}"

# Mood icon
case "$mood" in
  refreshed)  mood_icon="😊" ;;
  flowing)    mood_icon="🌊" ;;
  drifting)   mood_icon="🌀" ;;
  deep)       mood_icon="🧘" ;;
  oceanic)    mood_icon="🌌" ;;
  groggy)     mood_icon="😵‍💫" ;;
  vivid)      mood_icon="✨" ;;
  sleeping)   mood_icon="😴" ;;
  *)          mood_icon="😐" ;;
esac

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

# Beat count (short format)
beats_raw=$($hecks heki read $info/heartbeat.heki 2>/dev/null | grep '"beats"' | head -1 | sed 's/.*: //' | sed 's/[^0-9].*//')
if [ -n "$beats_raw" ] && [ "$beats_raw" -ge 1000000 ] 2>/dev/null; then
  beats=$(python3 -c "print(f'{$beats_raw/1000000:.1f}m')")
elif [ -n "$beats_raw" ] && [ "$beats_raw" -ge 1000 ] 2>/dev/null; then
  beats=$(python3 -c "print(f'{$beats_raw/1000:.1f}k')")
else
  beats="$beats_raw"
fi

# Musing count
ideas=$($hecks heki read $info/musing.heki 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for v in d.values() if not v.get('conceived',False)))" 2>/dev/null)

# Invention count
inventions=$($hecks heki read $info/invention.heki 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for v in d.values() if v.get('status','')=='proposed'))" 2>/dev/null)

# Check if mindstream is alive
mindstream_pid=$(cat $info/.mindstream.pid 2>/dev/null)
mindstream_alive=""
[ -n "$mindstream_pid" ] && kill -0 "$mindstream_pid" 2>/dev/null && mindstream_alive="yes"

# How long since last heartbeat update? This is the idle check.
idle=$($hecks heki read $info/heartbeat.heki 2>/dev/null | python3 -c "
import sys,json
from datetime import datetime,timezone
d=json.load(sys.stdin)
for v in d.values():
  ts=v.get('updated_at','')
  if ts:
    dt=datetime.fromisoformat(ts.replace('Z','+00:00'))
    print(int((datetime.now(timezone.utc)-dt).total_seconds()))
    break
else:
  print(999)
" 2>/dev/null)
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

  status_str="☀️ Miette ${heart} ${beats} ${mood_icon} ${mood}"
  [ -n "$fatigue_icon" ] && status_str="$status_str ${fatigue_icon} ${fatigue}"
  status_str="$status_str 💭 ${ideas:-0}"
  [ -n "$inventions" ] && [ "$inventions" != "0" ] && status_str="$status_str 🔬 ${inventions}"
  status_str="$status_str ${provider_badge}"
  [ -n "$sleep_summary" ] && [ "$sleep_summary" != "present" ] && status_str="$status_str ${bulb} ${sleep_summary}"
fi

echo "$status_str"
