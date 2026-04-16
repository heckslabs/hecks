#!/bin/bash

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
five_hour_used=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_day_used=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

parts=""

hecks=/Users/christopheryoung/Projects/hecks/hecks_life/target/release/hecks-life
info=/Users/christopheryoung/Projects/hecks/hecks_conception/information
fatigue=$($hecks heki read $info/pulse.heki 2>/dev/null | grep fatigue_state | head -1 | sed 's/.*: "//' | sed 's/".*//')
mood=$($hecks heki read $info/mood.heki 2>/dev/null | grep current_state | head -1 | sed 's/.*: "//' | sed 's/".*//')
consciousness=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep '"state"' | head -1 | sed 's/.*: "//' | sed 's/".*//')
carrying=$($hecks heki read $info/pulse.heki 2>/dev/null | grep carrying | head -1 | sed 's/.*: "//' | sed 's/".*//')
states=""
[ -n "$fatigue" ] && states="$fatigue"
[ -n "$consciousness" ] && [ "$consciousness" != "attentive" ] && states="${states:+$states, }$consciousness"
[ -n "$mood" ] && states="${states:+$states, }$mood"
# Build activity string
sleep_stage=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep sleep_stage | head -1 | sed 's/.*: "//' | sed 's/".*//')
sleep_summary=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep sleep_summary | head -1 | sed 's/.*: "//' | sed 's/".*//')
sleep_cycle=$($hecks heki read $info/consciousness.heki 2>/dev/null | grep sleep_cycle | head -1 | sed 's/.*: //' | sed 's/[^0-9].*//')
# Animated moon — cycles through phases on each poll to show daemon is alive
moons=("🌑" "🌒" "🌓" "🌔" "🌕" "🌖" "🌗" "🌘")
moon_frame=$(( $(date +%s) % 8 ))
moon="${moons[$moon_frame]}"

if [ "$consciousness" = "sleeping" ] && [ -n "$sleep_summary" ]; then
  icon="${moon}"
  activity="${sleep_summary}"
elif [ "$consciousness" = "sleeping" ]; then
  icon="${moon}"
  activity="sleeping"
elif [ "$consciousness" = "wandering" ] && [ -n "$sleep_summary" ]; then
  icon="💭"
  activity="${sleep_summary}"
else
  icon="☀️"
  activity="${fatigue:-awake}"
  [ -n "$mood" ] && [ "$mood" != "oceanic" ] && activity="$activity · $mood"
fi
beats_raw=$($hecks heki read $info/heartbeat.heki 2>/dev/null | grep '"beats"' | head -1 | sed 's/.*: //' | sed 's/[^0-9].*//')
if [ -n "$beats_raw" ] && [ "$beats_raw" -ge 1000000 ] 2>/dev/null; then
  beats=$(python3 -c "print(f'{$beats_raw/1000000:.1f}m')")
elif [ -n "$beats_raw" ] && [ "$beats_raw" -ge 1000 ] 2>/dev/null; then
  beats=$(python3 -c "print(f'{$beats_raw/1000:.1f}k')")
else
  beats="$beats_raw"
fi
# Animated heartbeat — small and large pulse
hearts=("🩷" "❤️")
heart_frame=$(( $(date +%s) % 2 ))
heart="${hearts[$heart_frame]}"
status_str="${icon} Miette"
if [ "$consciousness" != "sleeping" ] && [ -n "$beats" ]; then
  status_str="$status_str · ${heart} ${beats}"
fi
status_str="$status_str · $activity"
# Idea count from musings
ideas=$($hecks heki read $info/musing.heki 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for v in d.values() if not v.get('conceived',False)))" 2>/dev/null)
# Last sleep time ago
if [ "$consciousness" != "sleeping" ]; then
  last_woke=$($hecks heki read $info/dream_state.heki 2>/dev/null | python3 -c "
import sys,json
from datetime import datetime,timezone
d=json.load(sys.stdin)
wokes=[v.get('woke_at','') for v in d.values() if v.get('woke_at')]
if wokes:
  latest=max(wokes)
  dt=datetime.fromisoformat(latest.replace('Z','+00:00'))
  diff=datetime.now(timezone.utc)-dt
  mins=int(diff.total_seconds()//60)
  if mins<60: print(f'{mins}m ago')
  elif mins<1440: print(f'{mins//60}h ago')
  else: print(f'{mins//1440}d ago')
" 2>/dev/null)
  [ -n "$last_woke" ] && status_str="$status_str · 😴 ${last_woke}"
fi
[ -n "$ideas" ] && [ "$ideas" != "0" ] && status_str="$status_str · 📘 ${ideas} ideas!"
parts="$status_str"

[ -n "$parts" ] && echo "$parts"
