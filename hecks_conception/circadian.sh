#!/bin/bash
# Circadian — wall-clock segment tracker. Wakes every 60 seconds,
# checks the hour, and dispatches the Mark* command when the day's
# segment has changed since the last check.
#
# Segments by hour (local time):
#   05:00-06:59  dawn
#   07:00-11:59  morning
#   12:00-16:59  afternoon
#   17:00-19:59  dusk
#   20:00-04:59  night
#
# Body cycles run independently of the mindstream. The daemon only
# dispatches when the segment transitions — a 60s idle tick inside
# the same segment is a no-op.
#
# [antibody-exempt: body-cycle shell daemon; retires when
# mindstream/heart/breath/circadian migrate to .bluebook + .hecksagon
# dispatched by hecks-life run (planned i3 PR-d)]

HECKS="../hecks_life/target/release/hecks-life"
DIR="$(dirname "$0")"
INFO="$DIR/information"
AGG="$DIR/aggregates"
PIDFILE="$INFO/.circadian.pid"

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

segment_for_hour() {
  hour=$1
  if [ "$hour" -ge 5 ] && [ "$hour" -le 6 ]; then
    echo "dawn"
  elif [ "$hour" -ge 7 ] && [ "$hour" -le 11 ]; then
    echo "morning"
  elif [ "$hour" -ge 12 ] && [ "$hour" -le 16 ]; then
    echo "afternoon"
  elif [ "$hour" -ge 17 ] && [ "$hour" -le 19 ]; then
    echo "dusk"
  else
    echo "night"
  fi
}

last_segment=""

while true; do
  hour=$(date +%H | sed 's/^0//')
  [ -z "$hour" ] && hour=0
  segment=$(segment_for_hour "$hour")
  if [ "$segment" != "$last_segment" ]; then
    case "$segment" in
      dawn)      cmd="Circadian.MarkDawn" ;;
      morning)   cmd="Circadian.MarkMorning" ;;
      afternoon) cmd="Circadian.MarkAfternoon" ;;
      dusk)      cmd="Circadian.MarkDusk" ;;
      night)     cmd="Circadian.MarkNight" ;;
    esac
    $HECKS "$AGG" "$cmd" 2>/dev/null
    last_segment="$segment"
  fi
  sleep 60
done
