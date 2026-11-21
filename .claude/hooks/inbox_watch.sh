#!/usr/bin/env bash
# Run under the Monitor tool: prints one line per new unread message for the session's own run,
# so a message wakes an idle session. It resolves the run key on every turn, so a run registered
# after the session started is still heard, and it ends before Monitor's 30 minute cap.
# It only reads: the next tool step delivers the body and marks the message read.
# Usage: inbox_watch.sh <session id>
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=session_run_key.sh
. "$here/session_run_key.sh"
d="${CLAUDE_PROJECT_DIR:-$(cd "$here/../.." && pwd)}"
turns="${HECKS_WATCH_TURNS:-58}"
pause="${HECKS_WATCH_PAUSE:-30}"
seen=" "

for ((turn = 1; turn <= turns; turn++)); do
  key="$(session_run_key "${1:-}")"
  key="${key:-${HECKS_RUN_KEY:-}}"
  if [ -n "$key" ]; then
    for id in $("$d/exe/hecks" agents query message.inbox "recipient.value=$key" 2>/dev/null | grep -oE '"id": "[^"]+"' | cut -d'"' -f4); do
      case "$seen" in *" $id "*) ;; *) seen="$seen$id "; echo "Hecks mail for $key: $id (your next tool step delivers it)" ;; esac
    done
  fi
  [ "$turn" -lt "$turns" ] && sleep "$pause"
done
