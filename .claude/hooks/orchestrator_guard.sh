#!/usr/bin/env bash
# PreToolUse hook for Bash: forwards the session's role and the command to the Agents bluebook's
# Role.guard query and relays its verdict. It decides nothing: the routing rows live in
# lib/hecks/agents/agents.bluebook, and a role with no rows is allowed by the query. A refusal exits
# 2, which hands the reason (the verb or role to use instead) back to the agent. A session with no
# role (the owner's) is never blocked.
#
# It forwards the session too, for the bluebook's `Script` rule: a role's session that runs a script
# before any hecks command since its last one is refused once with the `script` hint, and every
# script it runs is recorded. The rule is the Agents bluebook's; this hook names no interpreter.
#
# Before it asks, the hook decides what the projected rules (.claude/hooks/guard_rules.json) settle
# with no Hecks process: a call made by a subagent, a role with no routing rows, and a `git` or `gh`
# call that is exactly one of the role's rows. The file holds the digest of the Agents bluebooks it
# was projected from; a missing file or a digest that no longer matches turns this off, and the call
# goes to Role.guard, which reads the bluebooks and stays the one authority. Every launcher call and
# every other shape (a branch name after `git branch`, a pipe, a script) goes to Role.guard too.
#
# When Hecks cannot answer (the launcher fails, gives no verdict, or takes longer than the limit), a
# role listed in .claude/hooks/guarded_roles (projected from the RoutingRule rows) is refused with the
# reason, except for exactly `exe/hecks agents Role.guard` and `git status`, so a session can always
# read why and repair the guard. A missing list counts every role as guarded; a role not listed is
# warned and let through, as a role with no rows would be.
set -u

export PATH="$HOME/.rbenv/shims:/opt/homebrew/bin:/usr/local/bin:$PATH"

input="$(cat)"
role="$(printf '%s' "$input" | jq -r '.agent_type // empty')"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
agent="$(printf '%s' "$input" | jq -r '.agent_id // empty')"
session="$(printf '%s' "$input" | jq -r '.session_id // empty')"
[ -n "$role" ] && [ -n "$command" ] || exit 0

dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
guarded="$dir/.claude/hooks/guarded_roles"
limit="${HECKS_GUARD_LIMIT:-30}"

unanswered() {
  if [ -r "$guarded" ] && ! grep -qxF -- "$role" "$guarded"; then
    echo "orchestrator_guard: Hecks could not answer ($1); $role is not guarded, so not blocking" >&2
    exit 0
  fi
  case "$command" in "exe/hecks agents Role.guard" | "git status") exit 0 ;; esac
  echo "orchestrator_guard: Role.guard could not answer for $role ($1), so only" \
    "\`exe/hecks agents Role.guard\` and \`git status\` run until it does: run the first to see the" \
    "error, repair the guard, or ask the owner. Refused: $command" >&2
  exit 2
}

rules="$dir/.claude/hooks/guard_rules.json"

# Whether the projected rules, still current for this checkout's bluebooks, allow the call.
decided_by_rules() {
  [ -r "$rules" ] || return 1
  have="$(cd "$dir/lib/hecks/agents" 2>/dev/null && LC_ALL=C cat ./*.bluebook | shasum -a 256 | cut -d' ' -f1)"
  [ -n "$have" ] || return 1
  verdict="$(jq -r --arg have "$have" --arg role "$role" --arg command "$command" --arg agent "$agent" '
    if .digest != $have then "ask"
    elif $agent != "" or (.roles | has($role) | not) or ((.roles[$role] | index($command)) != null) then "allow"
    else "ask" end' "$rules" 2>/dev/null)"
  [ "$verdict" = "allow" ]
}

decided_by_rules && exit 0

cd "$dir" 2>/dev/null || unanswered "cannot enter $dir"
out="$(HECKS_CALLER=hook:orchestrator_guard perl -e 'alarm shift; exec @ARGV or exit 127' "$limit" \
  exe/hecks agents Role.guard "role.value=$role" "command.value=$command" "agent.value=$agent" \
  "session.value=$session" 2>&1)"
status=$?
[ "$status" -eq 0 ] && exit 0

reason="$(printf '%s\n' "$out" | grep -m1 'routes only')"
[ -n "$reason" ] && { printf '%s\n' "$reason" >&2; exit 2; }
[ "$status" -eq 142 ] && unanswered "no answer in ${limit}s"
unanswered "$(printf '%s\n' "$out" | grep -v '^\[hecks\]' | grep -v '^[[:space:]]*from ' | grep -m1 . | cut -c1-200)"
