#!/usr/bin/env bash
# SessionStart hook: registers a hand-started session as a run (`HandRun.register!`) so a message
# to its run key reaches it. It decides nothing: whether the session already has an AgentRun is
# `exe/hecks agent_run.running`'s answer, and the registration is the Agents bluebook's. The run key
# is `orchestrator` for the orchestrator seat, else `hand-<first 8 of the session id>`, so a resumed
# session registers under the same key. A session that has ended is no longer listed by
# `claude agents`, which is what a message to its key is refused on; there is nothing to retire.
# Install at the user level (~/.claude/settings.json, SessionStart) so it loads wherever a session
# starts; HECKS_CHECKOUT names the checkout whose launcher runs it.
set -u

export PATH="$HOME/.rbenv/shims:/opt/homebrew/bin:/usr/local/bin:$PATH"

input="$(cat)"
session="$(printf '%s' "$input" | jq -r '.session_id // empty')"
role="$(printf '%s' "$input" | jq -r '.agent_type // empty')"
[ -n "$session" ] || exit 0

checkout="${HECKS_CHECKOUT:-$HOME/Projects/hecks}"
launcher="$checkout/exe/hecks"
[ -x "$launcher" ] || exit 0

"$launcher" agent_run.running 2>/dev/null | grep -q "$session" && exit 0

case "$role" in
  orchestrator*) key="orchestrator" ;;
  *) key="hand-$(printf '%s' "$session" | cut -c1-8)" ;;
esac

"$launcher" agents HandRun.register! "run.value=$key" "session.value=$session" \
  "role.value=${role:-hand}" --wait >/dev/null 2>&1
exit 0
