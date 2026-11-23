#!/usr/bin/env bash
# Run under the Monitor tool: prints one line per new unread message for the session's own run,
# so a message wakes an idle session. It resolves the run key on every turn, so a run registered
# after the session started is still heard, and it ends before Monitor's 30 minute cap.
# It only reads, with sqlite3 and no boot: the events addressed to the run past its seat's cursor
# (the cursor row, or an advance still waiting in the spool). The next tool step delivers the body
# and moves the cursor. A seat with no cursor yet has none to hear: its first step opens one.
# Usage: inbox_watch.sh <session id>
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=session_run_key.sh
. "$here/session_run_key.sh"
dev="${HECKS_DEV_DIR:-$HOME/.claude/hecks-dev}"
spool="${HECKS_MAIL_SPOOL:-$dev/mail/spool.jsonl}"
lookup() { sqlite3 -readonly -cmd ".timeout 200" "$@" 2>/dev/null; }

# The ids of the events addressed to a run (as its latest event names it) past the seat's cursor.
unread() {
  local run="$1" stored waiting position
  stored="$(lookup "$dev/agents.db" "select json_extract(position,'\$.value') from seat_cursor where json_extract(seat,'\$.value')='$run' limit 1")"
  [ -f "$spool" ] && waiting="$(jq -rs --arg run "$run" '[.[] | select(.advance==$run or .open==$run) | .to] | max // empty' "$spool" 2>/dev/null)"
  position="$(printf '%s\n%s\n' "$stored" "${waiting:-}" | grep -E '^[0-9]+$' | sort -n | tail -1)"
  [ -n "$position" ] || return 0
  lookup "$dev/agents.db" "select a.aggregate_id from events a where a.name='MessageAddressed' and a.id>$position and (select json_extract(r.payload,'\$.recipient.value') from events r where r.aggregate_id=a.aggregate_id and r.name in ('MessageAddressed','MessageStamped','MessageRouted') order by r.id desc limit 1)='$run' order by a.id"
}
turns="${HECKS_WATCH_TURNS:-58}"
pause="${HECKS_WATCH_PAUSE:-30}"
seen=" "

for ((turn = 1; turn <= turns; turn++)); do
  key="$(session_run_key "${1:-}")"
  key="${key:-${HECKS_RUN_KEY:-}}"
  if [ -n "$key" ]; then
    for id in $(unread "$key"); do
      case "$seen" in *" $id "*) ;; *) seen="$seen$id "; echo "Hecks mail for $key: $id (your next tool step delivers it)" ;; esac
    done
  fi
  [ "$turn" -lt "$turns" ] && sleep "$pause"
done
