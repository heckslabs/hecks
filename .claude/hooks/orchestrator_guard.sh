#!/usr/bin/env bash
# PreToolUse hook for Bash: forwards the session's role and the command to the Agents bluebook's
# Role.guard query and relays its verdict, except for the calls its projected rules settle (below).
# The routing rows live in lib/hecks/agents/agents.bluebook, and a role with no rows is allowed by the query. A refusal exits
# 2, which hands the reason (the verb or role to use instead) back to the agent. A session with no
# role (the owner's) is never blocked.
#
# It forwards the session too, for the bluebook's `Script` rule: a role's session that runs a script
# before any hecks command since its last one is refused once with the `script` hint, and every
# script it runs is recorded. The rule is the Agents bluebook's; this hook names no interpreter.
#
# Before it asks, the hook decides what the projected rules (.claude/hooks/guard_rules.json) settle
# with no Hecks process: a call made by a subagent, a role with no routing rows, and a `git` or `gh`
# call that is exactly one of the role's rows. Every launcher call and every other shape (a branch
# name after `git branch`, a pipe, a script) is a check that needs live state, and goes to Role.guard.
# The file holds the digest of the Agents bluebooks it was projected from. A guarded role is refused
# when the file is missing or the digest no longer matches, so the hook never passes a call on old
# rules; only `exe/hecks agents Role.guard`, `git status` and the projection command itself run, so
# a session can always repair the file. A role that is not guarded is let through.
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
projection="exe/hecks regeneration_run.project_agent_roles!"

# Prints allow, ask, missing or stale: what the projected rules say of this call.
rules_say() {
  [ -r "$rules" ] || { echo missing; return; }
  have="$(cd "$dir/lib/hecks/agents" 2>/dev/null && LC_ALL=C cat ./*.bluebook | shasum -a 256 | cut -d' ' -f1)"
  [ -n "$have" ] || { echo missing; return; }
  jq -r --arg have "$have" --arg role "$role" --arg command "$command" --arg agent "$agent" '
    if .digest != $have then "stale"
    elif $agent != "" or (.roles | has($role) | not) or ((.roles[$role] | index($command)) != null) then "allow"
    else "ask" end' "$rules" 2>/dev/null || echo missing
}

# Refuses a guarded role's call, for rules that are not current, naming how to project them.
refuse_old_rules() {
  [ -r "$guarded" ] && ! grep -qxF -- "$role" "$guarded" && return 0
  case "$command" in "exe/hecks agents Role.guard" | "git status" | "$projection" | "$projection "*) return 0 ;; esac
  echo "orchestrator_guard: guard_rules.json is $1, so $role runs only \`exe/hecks agents Role.guard\`," \
    "\`git status\` and \`$projection\` until it is projected again: run the last." \
    "Refused: $command" >&2
  exit 2
}

case "$(rules_say)" in
  allow) exit 0 ;;
  missing) refuse_old_rules missing; exit 0 ;;
  stale) refuse_old_rules stale; exit 0 ;;
esac

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
