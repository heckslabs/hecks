# Runbook — use FQN internally (realm-qualified dispatch resolution) (2026-06-28)

## Goal (Chris)
Use the FULL FQN internally instead of short Domain::Aggregate names, so homonyms
across realms/domains can never collide. Today only the realm-OMITTED 2-segment
short form resolves ; every realm-qualified form fails — the friction that ran
through the whole :exec sweep (`result_into` had to be short, the door rejects
qualified FQNs, etc.).

## Empirical state (verified 2026-06-28, in-tree binary)
Dispatch `*.InboxPoller.Poll` against hecks_conception :
- `AgentInbox::InboxPoller.Poll`            (2-seg, Domain::Aggregate)        -> ok:true
- `Framework::AgentInbox::InboxPoller.Poll` (3-seg, Realm::Domain::Aggregate) -> UnknownCommand
- `Hecks::Framework::AgentInbox::InboxPoller.Poll` (4-seg, Root::Realm::…)    -> UnknownCommand

## Root semantics (the subtle part)
`heki.rs::folder_address_segments` stamps an aggregate's `realm_path` from its
SOURCE FOLDER, after dropping the *.bluebook file, the same-named container
folder (agent_inbox/agent_inbox stutter), and the literals hecks_conception /
aggregates / bluebook. For
`hecks/hecks_conception/aggregates/framework/agent_inbox/agent_inbox.bluebook`
the remaining segs are `[hecks, framework]` → **realm = "hecks", context =
"framework"** (proven by the folder_address_realm_plus_context unit test, which
stamps realm=hecks context=language/grammar for a grammar bluebook).

So the REALM is the repo dir (`hecks`), and `framework` is the CONTEXT. The DSL
root token in a binding FQN (`Hecks::…`) snake-cases to `hecks` — which DOES
equal the stamped realm. So `fqn_realm_context("Hecks::Framework::AgentInbox::
InboxPoller.Poll")` = (realm "hecks", context "framework"), and
`realm_context_matches("hecks/framework", "hecks", "framework")` returns TRUE.
The realm match is NOT the blocker for the 4-seg form.

## The two bugs
1. **3-seg form** (`Framework::AgentInbox::…`) : `fqn_realm_context` reads
   segs[0] = "Framework" as the realm → "framework", but the stamped realm is
   "hecks" → mismatch → fail. (The 3-seg Realm::Domain::Aggregate shape doesn't
   model the repo-as-realm + folder-as-context split.)
2. **4-seg form** (`Hecks::Framework::AgentInbox::…`) : realm + context BOTH
   match per the analysis above, yet it still returns UnknownCommand. So a
   SECOND bug lives in `resolve_fully_qualified` downstream of the realm gate —
   in `domain_matches(rt, ai, "AgentInbox", "agentinbox")` or the command
   lookup. NEEDS LIVE TRACING (add eprintln in the hits-collection loop : print
   agg.name, agg.realm_path, domain_matches result, realm_context_matches result
   for the InboxPoller candidate) to see which predicate rejects it.

## Files
- rust/src/runtime/command_dispatch.rs : `resolve_fully_qualified` (694),
  `parse_fqn` (677), `domain_matches`, `ambiguity_candidates`. EXEMPT kernel.
- rust/src/heki.rs : `fqn_realm_context` (FQN -> realm/context),
  `realm_context_matches`, `folder_address_segments` (folder -> realm_path).
- rust/src/runtime/policy_engine.rs : event matching (by_event bare name +
  aggregate qualifier + realm_path) — the EVENT side of the same FQN story.

## Plan (mechanical once the 4-seg bug is traced)
1. LIVE-TRACE the 4-seg failure (eprintln the predicate results) — find which of
   {domain_matches, realm_context_matches, command-name} rejects the known-good
   InboxPoller.Poll candidate.
2. Decide the CANONICAL internal FQN shape. Candidates :
   - `Root::Realm::Domain::Aggregate.Command` (4-seg, what bindings already use)
     — fix the downstream predicate so it resolves.
   - drop the realm semantics' repo-as-realm quirk so 3-seg Realm::Domain::Agg
     works too.
3. Make `resolve_fully_qualified` accept the canonical FQN (and keep the 2-seg
   short form as a convenience, OR flip the corpus fully to FQN).
4. EVENTS : extend policy `on` matching to the full FQN (realm::domain::
   aggregate.event) so event-name collisions (Swept x2) are impossible without
   relying on the aggregate-only qualifier (gap #1b).
5. Flip internal declarations (binding `on:`, :exec `command:`, policy `on`) to
   the canonical FQN. Gate : cargo test --release + 141 behaviors + integrity.

## Risk
This is the DISPATCH CORE. A wrong predicate change makes EVERY command
UnknownCommand. Trace first, change one predicate, run the full gate before the
next. Fresh-head work — not tail-of-a-long-session.
