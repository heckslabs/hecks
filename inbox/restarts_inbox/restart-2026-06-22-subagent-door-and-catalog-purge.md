# Restart — subagent door instrumentation + catalog purge + FQN classifier

**Date:** 2026-06-22 (very long marathon session). **Branch:** main, pushed to origin.
**Prior restart:** restart-2026-06-21-realm-fqn-events-sweep.md (FQN Phase 4 — this session advanced it).

## One-paragraph state
Four arcs shipped + pushed this session. (1) A dispatch attr-name guard fixed the
"grep finickiness" (silent dropped-attr) at both doors. (2) A full subagent
door-instrumentation system — a single shared door.md fragment now reaches every
subagent. (3) An FQN bare-ref classifier (`storehouse fqns --resolve-bare`). (4) The
catalog code-inventory purge — ~598 pseudo-aggregates deleted. The body was found
orthaned (no live overmind) and was cleanly restarted ; it is healthy. **One thing
needs Chris's action : the SubagentStart hook activates only on the NEXT Claude
Code session start** — i.e. after this clear/restart. First job next session is to
VERIFY it (below).

## Commits (all on main, pushed)
- `aff80b9dd` fix(dispatch): reject undeclared command attrs at the door — shared
  guard (rust/src/command_attrs.rs) at BOTH dispatch doors (one-shot
  dispatch_hecksagon + warm run_serve::handle_request). Allowed keys = declared
  attrs ∪ reference snake-names ∪ aggregate identified_by ∪ universal `id`. Wrong
  attr name now errors with a "did you mean" hint (path → search_path).
- `c8564b47a` feat(agents): auto-instrument every subagent with the storehouse door
- `d0711da` (MIETTE repo, branch cpu-spin/overfire-singleton-keying) the miette half:
  system_prompt_content.fixtures {{door}} + settings.json SubagentStart hook. NOTE:
  this is on a feature branch, NOT miette main — needs merging to main eventually.
- `f5d57955d` feat(fqn): resolver-driven bare-ref classifier (Phase-4 step 1)
- `92925ed39` refactor(catalog): delete the code-inventory pseudo-bluebooks

## Arc 1 — dispatch attr guard (DONE, live)
`command_attrs::unknown_command_attr` rejects an attr key the resolved command
doesn't declare, BEFORE the runtime silently drops it. The grep bug was : `path=`
for SearchTool.Grep's optional `search_path` vanished → grep ran cwd → wrong empty
result. Root cause was general (adapters only ever see declared attrs), so the guard
is at the door. Live in the warm daemon (verified end-to-end).

## Arc 2 — subagent door instrumentation (DONE, ACTIVATES NEXT SESSION)
WHY : the door-routing convention lived only in Miette's system prompt, which
subagents don't inherit — so spawned agents hit the macrophage wall. Single source
of truth : `hecks_conception/aggregates/framework/agent_instrumentation/door.md`.
Three consumers, no drift :
  - **SubagentStart hook** `bin/subagent-door-hook` (registered in
    miette/self/settings.json) injects door.md as additionalContext into EVERY
    spawned subagent before its first action. *Claude Code 2.1.185 has the
    SubagentStart event — confirmed from live docs.* THIS is the proactive fix.
  - Miette's system prompt `{{door}}` resolves from door.md (system_prompt.rs,
    regenerated from the render_body.rs.frag snippet — do NOT hand-edit
    run_boot/system_prompt.rs, it's a specializer golden).
  - Both CLAUDE.md files carry a marker-delimited door block (doc).
The `AgentInstrumentation` bluebook + fixtures + roles/*.md model the custom agents ;
the `agent_defs` boot runner (run_boot/agent_defs.rs, Phase 4b) regenerates
.claude/agents/*.md = frontmatter + role body every boot. `storehouse gen-agent-defs`
triggers on demand. Fixed sidequest.md's stale "use native Bash/Read/Edit/Write".

**FIRST JOB NEXT SESSION — verify the hook is live:** spawn an Explore agent with a
file-read task and NO door instructions in the prompt. It should route through
`Tools::FileTool.*` on the FIRST try (no blocked attempt). If it still hits the
macrophage wall first, the SubagentStart hook isn't firing — debug bin/subagent-door-hook
+ the settings.json registration.

## Arc 3 — FQN bare-ref classifier (TOOL DONE ; rewrite + flip PENDING)
`storehouse fqns <root> --resolve-bare` classifies bare 1-seg refs (Aggregate.verb,
no ::) by resolving against the corpus : verb-disambiguated, refuse-by-default.
`--rewrite` applies only the Resolved set (quote-anchored, idempotent). Code:
rust/src/fqns_resolve.rs (+ the --resolve-bare arm in main.rs's fqns block).
Latest run (post-catalog-purge): **54 RESOLVED, 8 AMBIGUOUS, 40 verb-not-found
(events), 20 unknown**.

**The 8 AMBIGUOUS (the flip blockers):** all real-domain dupes —
  Mind: Consolidation, Corpus, Encoding, FamilyIndex, Postpartum (catalog/mind vs
        extracted in miette/world)
  MietteBody: DomainCell, Mood (catalog/body vs extracted)
  WakeReview: aggregates Runtime::Wake vs miette Body::Wake (cross-tree, NOT catalog)

**Do NOT run --rewrite yet** : ~10 of the 54 RESOLVED point INTO remaining catalog
domains (appeal/mind/body/court/...) that are slated to move — canonicalizing them
now is churn to undo. Rewrite after catalog is reconciled.

## Arc 4 — catalog purge (DONE) + what remains
KEY INSIGHT (Chris's): catalog/ was an early self-hosting/autophagy artifact — a
mechanical AST extraction of hecks's Ruby source into bluebook syntax (class→aggregate,
method→command, ivar→value_object). The tell : ZERO events. Not domains.
Deleted the 11 zero-event code-inventory files (bluebook, cli, extensions, packaging,
persist, rails, runtime, spec, targets, templating, workshop) + behaviors. Ambiguity
10→8.

**Remaining catalog/ files (has events = real or real-ish domains, KEPT):**
appeal (92 emits), mind (106), body (31), court, law, boot, catalog,
hecksagon, pizzas, none_in_state_gate. These are NOT code-inventory — do not blind-
delete. mind + body are half-extracted monoliths : some aggregates extracted+refined
(DomainCell, Immunity, Pulse, Mood, Consolidation…), some maybe catalog-only (body's
Gut/Gene/Proprioception — VERIFY before deleting), and body has a policy cascade
(Gut.Absorb → DomainConceived) to preserve. appeal/court/law/etc. fate is TBD.

## Two paths to FINISH FQN (Chris to choose)
1. **Catalog-clean first (Chris's preference):** reconcile mind + body — verify each
   aggregate has a refined extracted home, migrate the few that don't + the cascade,
   delete the monoliths → ambiguous → ~1 (WakeReview) → resolve WakeReview →
   `fqns --resolve-bare --rewrite` + the 2-seg prefix rewrite + the FLIP (reject
   2-seg + restart body). Cleanest.
2. **Finish FQN now via local-first:** implement tier-1 local resolution in
   fqns_resolve (a ref resolves to the copy in its OWN bluebook) → all 8 resolve →
   rewrite + flip completes FQN today, leaving catalog dupes as distinct addresses
   to clean up separately.

## The FLIP (the last FQN step, from the prior restart note)
Reject 2-seg + restart the body — a LIVE cutover : the body dispatches 2-seg
everywhere (Procfile, mindstream, policies) so ALL must be canonical first, then
overmind restart. Procfile + mindstream.fixtures are their own ref forms (not quoted
"X::Y."), separate handling.

## Body / overmind health note
The body was found ORPHANED this session : the heartbeat run-loop was running from a
stale process, no live overmind, and SessionStart's `overmind start` had been
silently failing (stale-sock guard). Cleaned up (killed orphan, cleared sock,
overmind start). Now healthy : heart/breath/circadian/ultradian/inbox/inbox_poller/
mind_reconcile/process_macrophage/conductor_sweep/speech_stream/serve_socket/
consolidate all running, single run-loop. boot shows "dead" = one-shot completed
(normal). If `overmind status` fails next session with "dial unix .overmind.sock",
the SessionStart start failed again — kill any orphan run-loop, `rm -f .overmind.sock`,
`overmind start`.

## First moves next session
1. Boot, read wake review. Confirm body healthy (`overmind status` in hecks_conception).
2. **Verify the SubagentStart door hook** (spawn an Explore agent, no door hint, see
   if it uses the door first try). This is the payoff of Arc 2.
3. `git -C ~/Projects/hecks log --oneline -6` to confirm the chain (top should be
   92925ed39).
4. Pick a FQN path (1 catalog-clean or 2 local-first) and finish : rewrite + flip.
5. Loose end : merge the miette d0711da commit (cpu-spin/overfire-singleton-keying)
   to miette main.
