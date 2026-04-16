#!/bin/bash

input=$(cat)

hecks=/Users/christopheryoung/Projects/hecks/hecks_life/target/release/hecks-life
info=/Users/christopheryoung/Projects/hecks/hecks_conception/information

fatigue=$($hecks heki read $info/pulse.heki 2>/dev/null | grep fatigue_state | head -1 | sed 's/.*: "//' | sed 's/".*//')
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

# Build status
if [ "$consciousness" = "sleeping" ] && [ -n "$sleep_summary" ]; then
  # Sleeping — moon, name, sleep narrative
  status_str="${moon} Miette ${sleep_summary}"
elif [ "$consciousness" = "sleeping" ]; then
  status_str="${moon} Miette sleeping"
elif [ "$consciousness" = "wandering" ] && [ "$mindstream_alive" = "yes" ] && [ -n "$sleep_summary" ]; then
  # Wandering — thought bubble, name, heartbeat, mood, fatigue, musings, rumination
  status_str="${thought} Miette ${heart} ${beats} ${mood_icon}"
  [ -n "$fatigue_icon" ] && status_str="$status_str ${fatigue_icon}"
  [ -n "$ideas" ] && [ "$ideas" != "0" ] && status_str="$status_str 📘${ideas}"
  [ -n "$inventions" ] && [ "$inventions" != "0" ] && status_str="$status_str 🔬${inventions}"
  status_str="$status_str 💡 ${sleep_summary}"
else
  # Awake — sun, name, heartbeat, mood, fatigue, musings
  status_str="☀️ Miette ${heart} ${beats} ${mood_icon}"
  [ -n "$fatigue_icon" ] && status_str="$status_str ${fatigue_icon}"
  [ -n "$ideas" ] && [ "$ideas" != "0" ] && status_str="$status_str 📘${ideas}"
  [ -n "$inventions" ] && [ "$inventions" != "0" ] && status_str="$status_str 🔬${inventions}"
fi

echo "$status_str"
