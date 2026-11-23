#!/usr/bin/env bash
# A mark: appends one JSON line to the mail spool saying a seat's cursor passed an event, and
# nothing else, so it takes milliseconds and boots no domain. Hecks ingests the line as
# `SeatCursor.Advance` (or `Open`, for a seat's first mark) on the clock's beat.
# Usage: mail_mark.sh advance|open <seat> <event position>
set -u
[ "$#" -eq 3 ] || { echo "usage: mail_mark.sh advance|open <seat> <position>" >&2; exit 2; }
case "$1" in advance|open) ;; *) echo "mail_mark: advance or open" >&2; exit 2;; esac
case "$3" in ''|*[!0-9]*) echo "mail_mark: the position must be a number" >&2; exit 2;; esac

spool="${HECKS_MAIL_SPOOL:-${HECKS_DEV_DIR:-$HOME/.claude/hecks-dev}/mail/spool.jsonl}"
mkdir -p "$(dirname "$spool")"
jq -cn --arg kind "$1" --arg seat "$2" --argjson to "$3" '{($kind): $seat, to: $to}' >> "$spool"
