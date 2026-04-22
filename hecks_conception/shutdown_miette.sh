#!/bin/sh
# Shutdown Miette — send SIGTERM to every daemon with a pidfile in
# information/.*.pid. Pair for boot_miette.sh. Covers mindstream,
# heart, breath, circadian, and any future daemons that drop a
# pidfile in the same directory.
#
# [antibody-exempt: boot/shutdown shell script; complements
# boot_miette.sh and retires with the bluebook-native boot story]

set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
INFO="$DIR/information"

shutdown_pidfile() {
  pidfile="$1"
  [ -f "$pidfile" ] || return 0
  pid=$(cat "$pidfile" 2>/dev/null)
  name=$(basename "$pidfile" .pid | sed 's/^\.//')
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo "  stopped $name (pid $pid)"
  else
    echo "  $name: no live process for pidfile"
  fi
  rm -f "$pidfile"
}

echo "shutting down Miette daemons…"
for pidfile in "$INFO"/.*.pid; do
  [ -f "$pidfile" ] || continue
  shutdown_pidfile "$pidfile"
done
echo "✓ shutdown complete"
