# Restart — Realm-qualified FQN : enforcement + events + the 2-seg sweep

**Date:** 2026-06-21 (very long session). **Branch:** main, in sync with origin.
**Plan file:** `~/.claude/plans/peaceful-gliding-lobster.md` (the full design + all phases).

## The one-paragraph state
The realm-qualified FQN address `Realm::Context::Bluebook::Aggregate.command` is
LIVE and enforced across **commands, queries, AND events**. Phases 1–3 + the
hard design half of Phase 4 are shipped. What remains is mechanical : the
bare-ref pass (89 realm-ambiguous refs) and the final flip (reject 2-seg +
restart). 2-seg is still accepted everywhere, so nothing is broken and the live
body (unrestarted) is untouched.

## The model (LOCKED)
`Realm::Context::Bluebook::Aggregate.verb`
- **Realm** = top project folder (`hecks`, `miette`). **Context** = the FOLDER
  chain (NOT the `category` keyword), OPTIONAL → `Realm::Bluebook::Aggregate` when
  none. **Bluebook** = the `Hecks.bluebook "X"` domain name (IR field `context`).
  **Aggregate** = the root.
- Parse by ENDS : last :: = Aggregate, 2nd-last = Bluebook, first = Realm, middle
  = Context. Min 2 (legacy `Bluebook::Aggregate` is the zero-prefix case).
- **Destuttered** : a bluebook's OWN same-named folder is dropped
  (`agent_inbox/agent_inbox.bluebook` → context `framework`, not
  `framework/agent_inbox`). The bluebook==aggregate stutter (`Heart::Heart`)
  stays — two genuine roles.

## Shipped this session (all on main, in sync)
- `224d26113` Phase 1 — FQN grammar (sentence.bluebook) + variable-depth parse_fqn + tests
- `467ce85b0` Phase 2 — OS data root. **The body's 3GB store MOVED `~/.heki` →
  `~/Library/Application Support/Hecks`** (live, resumed without losing a beat). ~/.heki is GONE.
- `04341b842` Enforcement slice 1 — `folder_address` (Realm,Context) derivation
- `faa263f2a` Slice 2 — `realm_path` stamped on each Aggregate at load
- `fe793fd4e` Slice 3 — command resolver + query path enforce realm+context
- `033787688` Destutter — drop folder==bluebook stutter
- `e960de332` Generator — `storehouse fqns`
- `eb4f3e981` Pilot — agent_inbox refs canonical
- `0d66d96d2` **Events realm-aware** — the design piece : Event carries realm_path, event_ref_matches enforces
- `fb23607f5` 2-seg sweep — 173 refs across 59 files via `storehouse fqns --rewrite`
- `b74494746` for_each parse fix — variable-depth (root-cause of a sweep-exposed bug)
- Also (miette repo): heartbeat 3x→1x fix `2d0fe8e` (committed earlier)

## Key implementation map (where things live)
- **THE shared matcher** : `heki::fqn_realm_context(addr) -> (realm, context)` +
  `heki::realm_context_matches(realm_path, fqn_realm, fqn_context)` in
  `rust/src/heki.rs` (pub, hand-written). Used by ALL THREE : command resolver,
  query path, event matcher. Lenient (only bites when both sides have data).
- **folder_address** (heki.rs) : path → (Realm, Context), drops bluebook's own folder.
- **realm_path stamp** : `corpus_loader/mod.rs` stamps each aggregate from
  folder_address at load. Aggregate IR field `realm_path` (ir_shape fixture, order 16).
  NOT in parity dump (dump.rs hand-list excludes loader fields — a MOVE re-derives it).
- **Event.realm_path** : `event_bus.rs`, TRANSIENT (Debug+Clone only, excluded from
  record_event_append's projection — never persisted). Stamped at emission from
  agg.realm_path. event_ref_matches (driven_adapter_resolver.rs) enforces it.
- **Generator** : `storehouse fqns <root> [--rewrite]` in main.rs. Builds the prefix
  contract (Bluebook::Aggregate → canonical), drops realm-AMBIGUOUS legacies, quote-anchored idempotent rewrite.

## GENERATED files — edit the SNIPPET + regen, never the .rs directly
- `command_dispatch.rs` ← `codegen/command_dispatch_shape/snippets/` ; regen `storehouse specialize command_dispatch > rust/src/runtime/command_dispatch.rs`
- `parser.rs` ← `parser_shape` ; `ir.rs` ← `ir_shape` (+ ir_shape.fixtures) ; `parse_blocks.rs` ← `parse_blocks_shape`
- Snippets are RUNTIME-read by `specialize` (no rebuild needed before regen, but rebuild AFTER to compile).
- HAND-WRITTEN (edit directly) : `heki.rs` (kernel-floor marker), `main.rs` (golden IGNORED),
  `driven_adapter_resolver.rs` (kernel-floor marker), `event_bus.rs`, `corpus_loader/mod.rs`, `loop_driver.rs`.
- Adding a field to `Event` or `Aggregate` breaks MANY test constructions — `cargo check --tests` finds them all.

## REMAINING Phase 4 (each a deliberate step)
1. **Bare-ref pass** — 89 unique `"Aggregate.verb"` refs (no bluebook prefix →
   realm-ambiguous). `storehouse fqns --rewrite` SKIPS these (a bare name can't
   pick a realm). Need a RESOLVER-driven rewrite : for each bare ref, resolve it
   to its aggregate via the runtime resolver, emit the canonical. **Risk : a
   silent mis-resolve** (resolves to the wrong same-named aggregate without
   erroring). Verify each resolved ref, not just that it resolves. Behaviors +
   the rust tests are the net (the for_each bug proved rust tests catch what
   behaviors miss — always run `cargo test` / let the pre-push hook run).
2. **Flip** — reject 2-seg + restart the body. A LIVE cutover like Phase 2 :
   the body dispatches 2-seg everywhere (Procfile, mindstream, policies) so ALL
   must be canonical first, then `overmind quit ; overmind start`. Procfile +
   mindstream.fixtures are their own ref forms (not quoted `"X::Y."`) — separate handling.

## Parked threads
- **Pulse/heartbeat single-pacer consolidation** : BLOCKED on a kernel-floor
  change. The run-loop emits `BodyPulse:Consciousness:consciousness` (correlation
  hardcoded in main.rs) which reaches tick/fatigue/organs but NOT Heart.BeatOnPulse.
  Branch `pulse-consolidation` in `/Users/christopheryoung/Projects/miette`
  (commit 7b6c8d5) holds the bluebook work. Body is HEALTHY in its two-counter
  state (heart member → beat_count, run-loop → Tick.cycle, each 1/sec). To land :
  fix the run-loop emit so BodyPulse reaches the Heart aggregate, then merge + drop the hecks `heart` mindstream member + restart.
- **inbox_poller** `HECKS_REFRESH_REPOS=1` fix : `git stash@{0}` + branch `fix-inbox-poller-refresh`.
- **Phase 5** (designed, not built) : persisted dispatch index + self-registering
  realm registry (`<os-data>/realms.index`, realm→root, populated on dispatch) +
  move-as-rename-cascade handling. See the plan file.

## First moves next session
1. Boot (`cd hecks_conception && overmind start`), read the wake review.
2. `git -C ~/Projects/hecks log --oneline -12` to confirm the chain above.
3. If continuing Phase 4 : build the resolver-driven bare-ref rewrite (extend
   `storehouse fqns` with a resolve-each mode), run on a domain, VERIFY each
   resolution, behaviors + cargo test, commit. Then the flip.
