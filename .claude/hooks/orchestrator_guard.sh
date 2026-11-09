#!/usr/bin/env bash
# PreToolUse hook for Bash: forwards the session's role and the command to the Agents bluebook's
# Role.guard query and relays its verdict. It decides nothing: the routing rows live in
# lib/hecks/agents/agents.bluebook, and a role with no rows is allowed by the query. A refusal exits
# 2, which hands the reason (the verb or role to use instead) back to the agent. A session with no
# role, or a Hecks that could not run, warns and never blocks.
set -u

export PATH="$HOME/.rbenv/shims:/opt/homebrew/bin:/usr/local/bin:$PATH"

input="$(cat)"
role="$(printf '%s' "$input" | jq -r '.agent_type // empty')"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
agent="$(printf '%s' "$input" | jq -r '.agent_id // empty')"
[ -n "$role" ] && [ -n "$command" ] || exit 0

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" || exit 0
out="$(HECKS_CALLER=hook:orchestrator_guard exe/hecks agents Role.guard"role.value=$role" "command.value=$command" "agent.value=$agent" 2>&1)" && exit 0

reason="$(printf '%s\n' "$out" | grep -m1 'routes only')"
[ -n "$reason" ] || { echo "orchestrator_guard: Hecks could not answer; not blocking" >&2; exit 0; }
printf '%s\n' "$reason" >&2
exit 2
