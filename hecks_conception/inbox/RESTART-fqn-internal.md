# RESTART — use FQN internally (next task) + session landing (2026-06-28)

## DO THIS NEXT
**Read `hecks_conception/inbox/fqn-internal-resolution-runbook.md` and execute it.**
Chris wants the runtime to use the FULL FQN internally instead of short
Domain::Aggregate names, so homonyms across realms/domains can't collide. The
runbook has the precise diagnosis + the mechanical plan. START with the LIVE
TRACE (step 1) — it is the DISPATCH CORE, so trace the 4-seg failure (eprintln
the predicate results in resolve_fully_qualified), change ONE predicate, run the
FULL gate, repeat. Fresh-head, careful. A wrong change = every command
UnknownCommand.

Key facts already proven (don't re-derive) :
- Only the 2-seg short form `AgentInbox::InboxPoller.Poll` resolves today.
- realm_path is stamped realm=`hecks` (repo dir) + context=`framework` — the
  repo-is-realm quirk in heki.rs::folder_address_segments.
- 3-seg fails on realm mismatch ; 4-seg should match realm+context but still
  fails — a SECOND bug downstream (domain_matches / command lookup) needs the trace.

## WHAT LANDED THIS SESSION (all on origin/main, gated ; last = the :exec sweep)
1. **Stability** — fixed two dead Driver daemons (over-qualified driving-dispatch
   addresses, regression from fdcb1d0cc) ; reaped an 8.5h 100%-CPU runaway ;
   retired stale demo-main MergeQueue pollution ; bounced daemons to clear a
   stale-parse MCP-door split-brain.
2. **Hecksagon-first standard** — recorded via ChrisYoung.DeclareStandard +
   appended to miette_family/chris_young/standards.md + miette/self/system_prompt.md
   (the injected source). "Impure edges live in the hecksagon ; the bluebook
   parses bluebooks."
3. **The `:exec` synthesis (KERNEL)** — `adapter :exec, command:, exec:,
   result_into:` is SUGAR over the one Primitive::Process.Spawn primitive :
   resolve_exec_adapters (rust/src/runtime/reaction.rs, EXEMPT) matches each
   :exec IoAdapter whose command: == the dispatched Aggregate.Command and routes
   through resolve_primitive_spawn. Declaration in the hexagon, ONE spawn path,
   no bespoke per-family resolver. The :git_tool family (no resolver) was dropped.
4. **Full-command matcher** — the :exec matcher uses the FULL command portion
   (aggregate_type.command), not the bare last segment, so entity-scoped names
   (File.Move vs Directory.Remove) don't collide.
5. **EVERY impure edge re-homed** — ZERO Process.Spawn policies remain corpus-wide.
   28 :exec adapters across 11 hecksagons : process_health (sweep/heal/reap, LIVE
   on the daemon), inbox, fibroblast, sidequest, artifact_claim (all verified),
   git, cargo, plan, session, filesystem.

## OPEN FOLLOW-UPS (pre-existing gaps surfaced, NOT regressions)
- **filesystem** commands are dotted (File.Move) → the FQN parser reads aggregate
  `Filesystem.File`, so they're not addressable. Needs a rename File.Move->FileMove.
  The :exec adapters are in place for when it lands.
- **git / cargo / plan** bin scripts were never written (only story_*_check exist) ;
  those tool domains are script-less. Write the scripts or remove the domains.
- **MCP door bugs** (see inbox/mcp-door-dispatch-resolution-finding.md) : the door
  can't dispatch creation commands (Open) ; and it can surface a stale parallel
  consumer's result. Separate from the FQN flip but related.
- **:exec sugar** is built but the runbook inbox/exec-rehome-synthesis-runbook.md
  documents the full arc if more context is wanted.

## STANDARD IN FORCE
No impure edge in a bluebook. Hecksagon-first. Bluebook-first. Every imperative
leaf is a hexagon :exec adapter ; the bluebook only parses bluebooks.
