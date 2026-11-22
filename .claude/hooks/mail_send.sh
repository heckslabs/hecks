#!/usr/bin/env bash
# A send: appends one JSON line to the mail spool and nothing else, so it takes milliseconds and
# boots no domain. Hecks ingests the spool as the message ledger on the clock's beat.
# The sender is written as given: it is trusted, and signed sends wait for the off-laptop design.
# Usage: mail_send.sh <message key> <recipient run> <sender> <kind> <body> [in_reply_to]
# A line over 4000 bytes is refused, since only an append under PIPE_BUF is atomic.
set -u
[ "$#" -ge 5 ] || { echo "usage: mail_send.sh <message> <recipient> <sender> <kind> <body> [in_reply_to]" >&2; exit 2; }

spool="${HECKS_MAIL_SPOOL:-${HECKS_DEV_DIR:-$HOME/.claude/hecks-dev}/mail/spool.jsonl}"
line="$(jq -cn --arg message "$1" --arg recipient "$2" --arg sender "$3" --arg kind "$4" --arg body "$5" \
  --arg in_reply_to "${6:-}" '{message: $message, recipient: $recipient, sender: $sender, kind: $kind, body: $body, in_reply_to: $in_reply_to}')" || exit 2
[ "${#line}" -le 4000 ] || { echo "mail_send: the line is over 4000 bytes; shorten the body" >&2; exit 2; }

mkdir -p "$(dirname "$spool")"
printf '%s\n' "$line" >> "$spool"
