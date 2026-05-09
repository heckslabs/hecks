#!/bin/sh
# studio.sh — thin shell wrapper for the Hecks Studio Rack server.
#
# The studio is the rich in-process surface where Chris and Miette
# work together. This script execs `rackup config.ru` after bundle-
# resolving the Sinatra runtime declared in this directory's
# Gemfile. Sibling shape to tools/inbox/inbox.sh ; same intent —
# imperative shell today, bluebook-driven launch tomorrow.
#
# Usage :
#   studio.sh                       → bind 127.0.0.1, port 3100
#   studio.sh --port 4001           → bind 127.0.0.1, port 4001
#   studio.sh --bind 0.0.0.0        → bind 0.0.0.0,   port 3100
#   studio.sh --port 4001 --bind ::1
#
# Defaults bind to 127.0.0.1 — heki state is private and the
# studio exposes no auth. Override --bind only on a trusted host.

set -e

PORT=3100
BIND=127.0.0.1

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --bind) BIND="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "studio.sh: unknown arg $1" >&2 ; exit 1 ;;
  esac
done

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

# Pin the Gemfile explicitly. boot_miette.sh inherits a BUNDLE_GEMFILE
# from its parent context (often the installed hecks gem's Gemfile)
# which makes `bundle exec` look in the wrong place.
export BUNDLE_GEMFILE="$DIR/Gemfile"

exec bundle exec rackup config.ru -p "$PORT" -o "$BIND"
