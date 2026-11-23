#!/usr/bin/env bash
# PostToolUse hook for every tool: hands the session the messages sent to its run, so a message
# sent with `Message.send!` is heard within one tool step.
#
# The step is a read-only lookup with sqlite3 and boots nothing: the session is mapped to its run
# through the AgentRun ledger (or a registered HandRun), and the MessageAddressed events for that
# run past its seat's cursor are read from the Agents event log. The cursor is the seat's SeatCursor
# row plus any advance still waiting in the mail spool; a seat with none reads from now. The hook
# builds each message's text in order and marks the cursor (mail_mark.sh, one spool line) only up to
# the last message of the unbroken prefix it printed: a message whose text could not be built, and
# everything after it, is offered again next step.
# Ledgers are found under $HECKS_DEV_DIR or ~/.claude/hecks-dev. This hook decides nothing.
set -u

export PATH="$HOME/.rbenv/shims:/opt/homebrew/bin:/usr/local/bin:$PATH"

dev="${HECKS_DEV_DIR:-$HOME/.claude/hecks-dev}"
session="$(jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9-')"
[ -n "$session" ] && [ -f "$dev/agents.db" ] || exit 0

lookup() { sqlite3 -readonly -cmd ".timeout 200" "$@" 2>/dev/null; }

run="$(lookup "$dev/agent_run.db" "select json_extract(run,'\$.value') from agent_run where status='started' and json_extract(session,'\$.value')<>'' and '$session' like json_extract(session,'\$.value')||'%' limit 1")"
[ -n "$run" ] || run="$(lookup "$dev/agents.db" "select json_extract(run,'\$.value') from hand_run where json_extract(session,'\$.value')<>'' and '$session' like json_extract(session,'\$.value')||'%' limit 1")"
[ -n "$run" ] || exit 0
run="$(printf '%s' "$run" | tr -cd 'A-Za-z0-9._~-')"

spool="${HECKS_MAIL_SPOOL:-$dev/mail/spool.jsonl}"
d="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
db="$dev/agents.db"

stored="$(lookup "$db" "select json_extract(position,'\$.value') from seat_cursor where json_extract(seat,'\$.value')='$run' limit 1")"
waiting=""
[ -f "$spool" ] && waiting="$(jq -rs --arg run "$run" '[.[] | select(.advance==$run or .open==$run) | .to] | max // empty' "$spool" 2>/dev/null)"
position="$(printf '%s\n%s\n' "$stored" "$waiting" | grep -E '^[0-9]+$' | sort -n | tail -1)"

if [ -z "$position" ]; then
  newest="$(lookup "$db" "select coalesce(max(id),0) from events")"
  [ "${newest:-0}" -gt 0 ] && "$d/.claude/hooks/mail_mark.sh" open "$run" "$newest"
  exit 0
fi

# The recipient a message has now is the latest one an event of it names (a routed message moves).
rows="$(lookup -separator $'\t' "$db" "select a.id, a.payload from events a where a.name='MessageAddressed' and a.id>$position and (select json_extract(r.payload,'\$.recipient.value') from events r where r.aggregate_id=a.aggregate_id and r.name in ('MessageAddressed','MessageStamped','MessageRouted') order by r.id desc limit 1)='$run' order by a.id")"
[ -n "$rows" ] || exit 0

text=""
last=""
while IFS=$'\t' read -r id payload; do
  line="$(printf '%s' "$payload" | jq -r --arg run "$run" '"Message \(.message.value) from \(.sender.value) (\(.kind.value)): \(.body.value)\nYou may decline. To answer: exe/hecks agents Message.send! message.value=<new key> recipient.value=\(.sender.value) sender.value=\($run) kind.value=answer body.value=<your answer> in_reply_to.value=\(.message.value)\n"' 2>/dev/null)" || break
  [ -n "$line" ] || break
  text="$text$line
"
  last="$id"
done <<< "$rows"

[ -n "$last" ] || exit 0
jq -n --arg t "$text" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $t}}'
"$d/.claude/hooks/mail_mark.sh" advance "$run" "$last"
