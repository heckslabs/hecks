#!/usr/bin/env bash
# status.sh — Miette multi-system status report.
#
# Reads heki files via hecks-life, checks daemon pids, counts bluebooks,
# and prints a labeled, colored report. Honors NO_COLOR.
#
# Usage:
#   ./status.sh                           # full report
#   ./status.sh musings [--source=X]      # list musings, optionally filtered
#
# Environment:
#   HECKS_INFO   override information dir (default: ./information)
#   HECKS_LIFE   override hecks-life binary path
#   NO_COLOR     disable ANSI color

set -u

here="$(cd "$(dirname "$0")" && pwd)"
info="${HECKS_INFO:-$here/information}"

# Resolve hecks-life binary: env override wins; otherwise try worktree build,
# then fall back to the main repo's release build.
hecks="${HECKS_LIFE:-}"
if [ -z "$hecks" ]; then
  for cand in \
    "$here/../hecks_life/target/release/hecks-life" \
    "$here/../hecks_life/target/debug/hecks-life" \
    "/Users/christopheryoung/Projects/hecks/hecks_life/target/release/hecks-life"; do
    if [ -x "$cand" ]; then
      hecks="$cand"
      break
    fi
  done
fi

export HECKS_LIFE="$hecks"
export HECKS_INFO="$info"

pid_alive() {
  local pidfile="$1"
  if [ -f "$pidfile" ]; then
    local pid
    pid="$(cat "$pidfile" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo 1
      return
    fi
  fi
  echo 0
}

count_glob() {
  # Count files matching a glob, robust to zero matches.
  local n=0 f
  for f in $1; do
    [ -e "$f" ] && n=$((n + 1))
  done
  echo "$n"
}

mindstream_alive="$(pid_alive "$info/.mindstream.pid")"

agg_count="$(count_glob "$here/aggregates/*.bluebook")"
cap_count=0
if [ -d "$here/capabilities" ]; then
  cap_count=$(find "$here/capabilities" -name "*.bluebook" -type f 2>/dev/null | wc -l | tr -d ' ')
fi

# Honor subcommand `musings [--source=X]` — hand off to the python helper.
if [ "${1:-}" = "musings" ]; then
  shift
  exec python3 "$here/status_format.py" musings "$info" "$@"
fi

exec python3 "$here/status_format.py" \
  "$info" "$mindstream_alive" "$agg_count" "$cap_count" "$@"
