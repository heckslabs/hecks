# The orchestrator guard refuses when Role.guard cannot answer

**Status:** Accepted. Date: 2026-11-18. The architect reviewed the plan (work item
`guard-fails-closed-design`, verdict "sound with changes") and its smaller version is the one built.
Builds on the routing guard of the Agents bluebook (`Role.guard`, the `RoutingRule` rows).

## Context

`.claude/hooks/orchestrator_guard.sh` forwards each Bash command of a role's session to
`exe/hecks agents Role.guard` and relays a refusal. It let a command through whenever Hecks could not
answer, in five ways:

1. The hook called `Role.guard"role.value=$role"` with no space between the two words. Every call
   was `unknown_command: Role.guardrole.value=…`, which has no `routes only` line, so the hook warned
   and allowed. The guard enforced nothing from 2026-11-09 (522fbec5d) until this change.
2. Any non-zero exit without a `routes only` line was allowed: a boot error, a broken bluebook, a
   missing launcher.
3. A failed `cd` into the checkout was allowed.
4. The call had no bound. A Claude Code hook that runs past its timeout is a non-blocking error, so a
   hung boot also let the command through.
5. `.claude/settings.json` runs the hook only when it is executable (`[ -x "$hook" ] || exit 0`).

## Decision

1. **A guarded role is refused when Role.guard cannot answer.** A role is guarded when it has
   `RoutingRule` rows. "Cannot answer" means the launcher fails without a refusal, takes longer than
   30 seconds (`HECKS_GUARD_LIMIT`), or the checkout cannot be entered. The refusal names the role, the
   error's first line and the command.
2. **Two commands always run**, matched as exact strings: `exe/hecks agents Role.guard` (to see the
   error) and `git status`. No session is locked out of reading why and repairing the guard. The hook
   holds no other rule: it does not match prefixes, chaining or flags, since `RoutingGuard` and
   `ShellReads` already own them and a copy in shell would drift.
3. **The guarded roles are a projection.** `RegenerationRun.project_agent_roles` writes
   `.claude/hooks/guarded_roles` from the `RoutingRule` rows, beside the role files it already writes,
   so the hook knows whom to refuse without booting Hecks. `--check` catches drift. A missing list
   counts every role as guarded.
4. **A role with no routing rows and a session with no role are unchanged.** They are never refused,
   so a coder whose checkout cannot boot Hecks keeps its shell, and the owner's own session is not
   guarded.
5. **The executable bit is checked by a spec**, not by the settings line: the settings command stays
   a pass-through, and `spec/orchestrator_guard_hook_spec.rb` fails when the hook loses its mode.

## Consequences

- The orchestrator is guarded again. Commands it ran while the guard was open and that no
  `RoutingRule` row names are now refused by name.
- While Hecks cannot boot, the orchestrator runs only the two commands until the guard is repaired,
  which a coder does.
- `Role.guard` itself is not a `RoutingRule` row, so in a healthy checkout the orchestrator calling it
  is refused. Adding that row is a change to `lib/hecks/agents/agents.bluebook`, left for when that file
  is free.
- No bluebook aggregate, command, port or adapter changes. The rule stays in the Role aggregate's rows,
  and the hook stays a driving adapter that forwards.
