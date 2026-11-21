#!/usr/bin/env bash
# SessionStart hook: tells the session the one Monitor command that watches its own inbox, so a
# message wakes it. It decides nothing and boots nothing; the watcher it names does the reading.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=session_run_key.sh
. "$here/session_run_key.sh"
# shellcheck source=session_loops.sh
. "$here/session_loops.sh"
session="$(jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9-')"
[ -n "$session" ] || exit 0
key="$(session_run_key "$session")"
cmd="$here/inbox_watch.sh $session"

if [ -n "$key" ]; then
  who="Your run key is $key."
else
  who="No run is registered for this session yet: first run exe/hecks HandRun.register! run=<your key> session=$session role=<your role> --wait; the watcher reads that key on each turn."
fi
text="$who If you have the Monitor tool, start it now on this command (one line per new unread message for you): $cmd. Monitor ends it within 30 minutes: start it again when it ends. A line names only the message id; your next tool step delivers the body and marks it read."
text="$text$(session_loops_text "$session")"
jq -n --arg t "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $t}}'
