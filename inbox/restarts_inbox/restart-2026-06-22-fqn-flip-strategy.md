# Restart — FQN arc: bare-ref done, exhaustive 2-seg sweep is the path (NOT the flip)

**Date:** 2026-06-22 (very long marathon, follows restart-2026-06-22-subagent-door-and-catalog-purge.md).
**Branch:** main. Commits below are LOCAL, not pushed.

## One-paragraph state
The FQN arc's GOAL is met : ambiguity is **0**, corpus refs largely canonical,
the door is FQN-robust. Strategy PIVOTED away from "the flip" (reject 2-seg +
body restart — unbounded blast radius on the heartbeat) to : **keep the resolver
lenient (both 2-seg AND full FQN resolve), exhaustively sweep 2-seg -> FQN in
VERIFIED batches, and flip only when the 2-seg count is naturally ~0 (so the
flip is a no-op).** A door-brick happened mid-session (the bare-ref rewrite
corrupted tools.hecksagon's adapter `command:` key) and was root-caused + fixed.

## Commits this session (main, LOCAL, unpushed)
- `6ec038519` fix(hooks): bulletproof dispatch-detail-hook + add governed-door-hook
- `037bf326c` refactor(catalog): retire superseded mind+body monoliths (-5314 lines)
- `a18c21fce` refactor(wake): merge dual WakeReview into one mechanical pipeline
   (now at aggregates/miette/body/wake/wake.bluebook ; route-reachable ; verified live)
- `015e077f0` fix(runtime): FQN-robust adapter command matching (binding_command_tail)
- `40c528a85` refactor(fqn): canonicalize bare refs to full FQN (159 refs, 44 files)
- `1e585f7b1` fix(tools): correct wrong-realm Cascade ref in agent_tool driven adapter
- (miette repo, branch cpu-spin/overfire-singleton-keying) `a0690e0` retire :llm WakeReview

## THE KEY FIX (why the rewrite is now safe) — 015e077f0
resolve_claude_tool_adapters + the :mcp resolver matched a hecksagon binding's
`command:` against `target = aggregate_type.bare_command` (always 2-seg) by exact
string `==`. An FQN-canonicalized binding (`Hecks::Framework::Tools::ShellTool.Bash`)
stopped matching -> adapter never fired -> EMPTY door output, exit 0 (NOT a hard
error — silent). Fix : `binding_command_tail(c)` = `c.rsplit("::").next()` strips
the realm prefix before comparing, so a binding may be bare/2-seg/FQN. In
rust/src/runtime/mod.rs (~line 1927 claude_tool, ~2287 mcp ; helper near
strip_quotes_or_colon ~3772). VERIFIED : FQN binding fires, bare still fires.

## THE LOCKOUT (how the door-brick traps you, and the escape)
The door is the ONLY shell (native Bash/Read are NOT enabled in this context —
the settings reconcile's `permissions.deny` list blocks them, AND the harness
doesn't expose them ; subagents have no native tools either). So if the corpus
fails to load, EVERY door tool dies (Shell/File/Search) and you CANNOT self-revert.
The macrophage hook fails-OPEN on broken corpus (preserves a native fallback in
princple) but the deny-list fails-CLOSED (no fallback). RECOVERY required Chris to
run `git -C ~/Projects/hecks restore hecks_conception/` in his own terminal.
LESSON : never let a rewrite touch the door's own bluebooks without the matcher
fix in place ; and consider dropping the native-tool deny-list so the macrophage
hook (which fails open) is the sole governance layer -> self-recovery stays possible.

## Exhaustive 2-seg sweep — the bounded remaining work
`storehouse fqns <root>` (NO --resolve-bare) = the 2-seg PREFIX sweep ; add
`--rewrite` to apply. `--resolve-bare --rewrite` (the 1-seg pass) is DONE/committed.
The ~18 distinct 2-seg ref forms still in hecks_conception (run the inventory:
`grep -rhoE '\"[A-Za-z][A-Za-z]+::[A-Za-z]+\.[A-Za-z]+\"' hecks_conception
--include='*.bluebook' --include='*.hecksagon' --include='*.behaviors'
--include='*.fixtures' | grep -vE '::[A-Za-z]+::' | sort | uniq -c`):
  Discipline::GovernedDoor.Register(10), Voice::Voice.Speak(7), Tools::FileTool.Edit(3),
  Tools::Tools.Bash(2), Tools::SlackTool.Post(2), Inbox::Inbox.Check(2),
  Heartbeat::Heart.Beat(2), Discipline::AgentDiscipline.Register(2), various Tools::*(1).

### GOTCHAS — why a BLIND full sweep is wrong (do it BATCHED + verified):
1. **Wrong-domain refs** : `Heartbeat::Heart.Beat` — Heart is Miette::Body::Organs::Heart,
   NOT Cycles::Heartbeat. Verify the canonical before rewriting (like Tools::Cascade,
   which WAS a bug, fixed in 1e585f7b1). The prefix sweep maps by name and can mis-map.
2. **Driver refs are RESTART-RISKY** : Inbox::Inbox.Check etc. live in the Procfile,
   GENERATED from aggregates/framework/mindstream/mindstream.fixtures. Canonicalizing
   them needs Procfile regen (`storehouse specialize procfile`) + overmind restart, and
   a wrong organ FQN = dead organ. Do drivers LAST, test-gated (dispatch each FQN with
   the binary BEFORE restart). Driver canonical FQNs (from `fqns <root>`):
     Heart::Heart.Beat -> Miette::Body::Organs::Heart::Heart.Beat (miette root)
     Reconciler -> Mietteai::MietteMind::Reconciler.Reconcile (mietteai root)
     ...map the rest via `storehouse fqns /Users/christopheryoung/Projects/miette` etc.
3. **Examples must NOT be swept** : `Domain::Aggregate.Command` (grammar placeholder),
   `Pizza::Order.OrderAuthorized` (pizzas sample event).
4. **Tool bug** : the prefix-map has a malformed entry `DispatchMetaShape ->
   Hecks::Codegen::DispatchMetaShapeShape::...` (doubled "Shape"). HARMLESS today (no
   source ref matches it) but fix the fqns_resolve prefix logic before trusting a blind run.

### SAFE sweep recipe (per batch):
  - copy corpus is NOT enough (loses ../miette context -> resolves 0). Work on live
    with SELF-HEAL : rewrite -> probe door (`storehouse <root> Tools::ShellTool.Bash
    shell_command='echo OK'` | grep OK) -> if empty, `git restore hecks_conception/`
    IN THE SAME shell (plain git runs even when door is dead). The outer dispatch
    started pre-rewrite so it completes + auto-reverts. (See /tmp/fqn_rewrite_selfheal.sh.)
  - after each batch : door probe + run the wake (`storehouse storehouse route
    WakeReview.ComposeWakeReview` -> /tmp/wake_review_latest.md regenerates) + spot-check
    the swept refs resolve (`storehouse storehouse lookup <ref>`).

## THE FLIP (deferred until 2-seg ~0)
Make `realm_context_matches` (rust/src/runtime/command_dispatch.rs, via
resolve_fully_qualified ~626) STRICT — reject a ref that omits the realm. GLOBAL
blast radius (every ::-dispatch, every internal cascade). Only safe when no live
dispatch uses 2-seg. Then one calm overmind restart + verify all daemons.

## First moves next session
1. Boot, confirm body healthy + door alive (`storehouse <root> Tools::ShellTool.Bash echo OK`).
2. `git -C ~/Projects/hecks log --oneline -7` (top should be 1e585f7b1). Push if Chris wants.
3. Batched 2-seg sweep : start with the SAFE source batch (Voice, Discipline::*, Tools::*),
   verify the wrong-domain ones (Heartbeat::Heart) by hand, self-heal each batch.
4. Drivers LAST (mindstream.fixtures -> regen Procfile -> test-gate -> restart).
5. Optional : a validator_corpus WARNING rule for 2-seg refs (measures the bake, bluebook-first).
6. Flip only when the inventory is examples-only.
