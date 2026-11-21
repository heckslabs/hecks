#!/usr/bin/env bash
# PostToolUse hook for every tool: hands the session the messages sent to its run, so a message
# sent with `Message.send!` is heard within one tool step.
#
# The per-step check is a read-only lookup with sqlite3 and boots nothing: the session is mapped
# to its run through the AgentRun ledger (or a registered HandRun), and the run's unread messages
# are read from the Agents ledger. Hecks boots only when a message is waiting, to record it handed
# over with `Message.receive!`; the Message bluebook then marks it read itself. A message whose
# hand-over fails stays sent and is offered again next step; one whose read is refused stays delivered.
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

rows="$(lookup -json "$dev/agents.db" "select json_extract(message,'\$.value') as id, json_extract(sender,'\$.value') as sender, json_extract(kind,'\$.value') as kind, json_extract(body,'\$.value') as body from message where status='sent' and json_extract(recipient,'\$.value')='$run' order by id")"
[ -n "$rows" ] || exit 0

d="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
text=""
while IFS= read -r id; do
  "$d/exe/hecks" agents Message.receive! "to=$id" "reader=$session" >/dev/null 2>&1 || continue
  line="$(printf '%s' "$rows" | jq -r --arg id "$id" '.[] | select(.id==$id) | "Message \(.id) from \(.sender) (\(.kind)): \(.body)"')"
  text="$text$line
You may decline. To answer: exe/hecks agents Message.send! message.value=<new key> recipient.value=$(printf '%s' "$rows" | jq -r --arg id "$id" '.[]|select(.id==$id)|.sender') sender.value=$run kind.value=answer body.value=<your answer> in_reply_to.value=$id

"
done < <(printf '%s' "$rows" | jq -r '.[].id')

[ -n "$text" ] || exit 0
jq -n --arg t "$text" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $t}}'
