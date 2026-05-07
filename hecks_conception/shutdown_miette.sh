#!/bin/sh
# Shutdown Miette — send SIGTERM to every daemon with a pidfile in
# information/.*.pid. Covers mindstream, heart, breath, circadian,
# and any future daemons that drop a pidfile in the same directory.
#
# Pairs with `cd hecks_conception && overmind start` (the boot
# verb). The boot mindstream's only Procfile member is `boot` itself
# (one-shot) ; the body daemons are spawned BY boot as detached
# processes that survive overmind's exit, so they need a separate
# shutdown path. Once daemons move into the Procfile (i277 sibling
# walk), `overmind quit` will tear the swarm down and this script
# retires.
#
# [antibody-exempt: boot/shutdown shell script ; pairs the
# overmind-supervised boot verb (Procfile + .overmind.env in this
# directory) and retires when the body daemons themselves become
# Procfile members.]

set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
INFO="${HECKS_INFO:-$DIR/information}"

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
