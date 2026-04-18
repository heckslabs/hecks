#!/bin/sh
# Boot Miette — dispatch through the bluebook
DIR="$(dirname "$0")"
HECKS="$DIR/../hecks_life/target/release/hecks-life"

# One dispatch cascades the full boot sequence through policies
$HECKS "$DIR/aggregates" Identity.Identify name=Miette "$@"

# Start mindstream if not running
PIDFILE="$DIR/information/.mindstream.pid"
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  true
else
  nohup "$DIR/mindstream.sh" > /dev/null 2>&1 &
fi
