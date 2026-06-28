# Runbook — local-short / foreign-FQN dispatch addressing (CORRECTED 2026-06-28)

## This SUPERSEDES the prior runbook, which was WRONG
The prior version claimed a dispatch-core bug (a "mysterious 4-seg downstream
failure") and proposed using the FULL FQN internally everywhere. Both were wrong.
Proven this session against the live binary :

- **There is no dispatch-core bug.** The designed FQN
  `Realm::Context::Bluebook::Aggregate.verb` already resolves, and the corpus
  already uses it (`evaluation.bluebook` triggers
  `Hecks::World::Training::Evaluation::Evaluation.EvaluateModel`, green today).
- The "4-seg friction" was an **under-qualified address** — missing the bluebook
  segment. The bluebook NAME is a distinct address segment; `realm_path` is the
  folder path WITHOUT it. `fqn_realm_context`'s `segs[1..n-2]` was correct.
- A prototyped "folder-exact" kernel change (drop the bluebook segment,
  `segs[1..n-1]`) BROKE 2 behaviors (fine_tune, conception) because it rejects
  the designed bluebook-segment form the corpus already uses. Reverted. Folder-
  exact REJECTED by Chris.

## The DECISION (Chris, 2026-06-28) — local-short / foreign-FQN
ONE rule, not two formats — matches the Hexagon chapter ("the domain handles its
own intra-domain aggregate calls by naming convention; the hexagon wires only the
edges that LEAVE the domain") :

| Call | Form | Resolution |
|------|------|-----------|
| same bluebook (local) | `InboxPoller.Poll` (short) | scoped to the CALLER's bluebook; ERROR if absent locally |
| crosses bluebook (foreign) | `Hecks::World::Training::Evaluation.EvaluateModel` (full FQN) | exact, collision-proof |

Local stays short and readable; only edges that LEAVE the bluebook carry the FQN
(and thus the honest `::Evaluation::Evaluation` repeat — folder vs bluebook vs
aggregate are three axes that often share a word). This kills the doubling for
the common (local) case and collapses the migration : most of ~1900 address
sites are same-bluebook and STAY SHORT — only foreign edges flip.

## The safety gap today
`resolve()` resolves a short ref by GLOBAL FIRST-MATCH across every aggregate
(command_dispatch.rs `resolve()`, the dotted `[agg, cmd]` and bare `[cmd]` paths;
plus `resolve_fully_qualified` treats a realm-less 2-seg `Bluebook::Aggregate` as
lenient → first match). That is the homonym risk (Swept x2, Macrophage x2). The
model replaces it with CALLER-SCOPED resolution.

## Caller-context availability (VERIFIED this session)
- `resolve(rt, command_name)` is called inside `dispatch_inner`
  (command_dispatch.rs:119), which already receives
  `cascade_hint: Option<(upstream_type, upstream_id)>`.
- For a **policy `trigger`** : the upstream aggregate IS the declaring bluebook →
  `cascade_hint.0`'s `realm_path` = the local scope. AVAILABLE.
- For a **cross-domain driven adapter** (`driven on A's Event -> dispatch X`,
  declared in bluebook B) : true local scope is B, but `cascade_hint` = A. So the
  IR must STAMP the declaring bluebook onto driven/driving dispatch declarations.
- **Behaviors** : the file belongs to one bluebook; the `storehouse behaviors`
  harness knows it → scope from the file.
- **Top-level dispatch** (MCP/CLI) : `cascade_hint = None` → no local scope →
  FQN required. Correct by construction.

## Implementation sequence (flip-then-tighten ; gate between each)
1. **resolve() becomes caller-scope-aware, ADDITIVE** : thread
   `caller_scope: Option<&realm_path>` from `cascade_hint` (upstream aggregate's
   realm_path) through `dispatch_inner` into `resolve()`. A short ref prefers a
   LOCAL match (realm_path == caller_scope); FALLS BACK to today's global first-
   match if none. Breaks nothing (fallback preserves current behavior); only
   improves local-homonym correctness. Gate.
2. **Stamp declaring-scope** on driven/driving dispatch declarations in the IR
   (the cross-domain-driven gap above) + thread behaviors-file scope. Gate.
3. **Flip FOREIGN refs to FQN** : for every address site whose target aggregate
   is in a DIFFERENT bluebook than the declaring file, qualify to the canonical
   FQN. DERIVE via the runtime (`fqns_resolve::canonical_prefix` /
   `storehouse fqns`), foreign-aware — NOT regex. Local refs stay short. Gate.
4. **Tighten** : remove the global first-match fallback from step 1. A short ref
   now resolves local-ONLY; absent-local is an error. Homonyms structurally
   impossible. Gate.
5. **Events** : extend policy/driven `on` event matching to the full FQN for
   FOREIGN event subscriptions (Swept x2 can't collide), local stays short.

## Files
- rust/src/runtime/command_dispatch.rs : `resolve` (470), `resolve_fully_qualified`
  (694), `dispatch_inner` (113, has cascade_hint), `dispatch_cascade` (103).
- rust/src/heki.rs : `fqn_realm_context` (1083, CORRECT — do not change),
  `realm_context_matches` (1110), `folder_address_segments` (1040).
- rust/src/fqns_resolve.rs : `canonical_prefix` (35), `resolve_bare` — the derive
  source for the foreign-ref flip.
- rust/cli/src/main.rs : `fqns` subcommand (621) — `--rewrite` (2-seg sweep),
  `--resolve-bare --rewrite`. Needs a FOREIGN-AWARE mode (only flip cross-bluebook).

## Build/gate notes (cost me an hour this session — DO NOT REPEAT)
- The binary is the **storehouse-cli** package, NOT the `storehouse` lib. Build with
  `cargo build --release -p storehouse-cli`. A plain `cargo build --release` in rust/
  builds only the LIB and leaves the CLI binary STALE (mtime won't move).
- NEVER pipe cargo through `| tail` when you care about success — the pipe SWALLOWS
  cargo's non-zero exit. Check `${PIPESTATUS[0]}` or run unpiped with `echo EXIT=$?`.
- Gate : `cargo test -p storehouse` + the behaviors corpus (pre-push loop over
  hecks_conception/{aggregates,adapters,catalog} : 105 .behaviors, must stay 105/105).
- macOS `ls --time-style` is unsupported (BSD ls) — use `stat -f %Sm -t %H:%M:%S`.

## PROGRESS (2026-06-28)
- DONE c7d7724e4 — step 1 : caller-scoped local-first resolve (additive, fallback kept).
  3 unit tests prove it. caller_scope = cascade_hint upstream's realm_path.
- DONE ee7fb4076 — step 3 : `storehouse fqns --foreign-only` + corpus flip. 40
  foreign 2-seg refs -> FQN ; local refs stay bare. Tool is in cli/src/main.rs.

## REMAINING (in order ; each gated)
- **step 2 (declaring-scope stamp)** — caller_scope today = cascade_hint upstream
  (the EVENT SOURCE). For a cross-domain driven adapter (`driven on A.Event ->
  dispatch X` declared in bluebook B) the true local scope is B, not A. Stamp the
  declaring bluebook onto driven/driving dispatch declarations in the IR + thread
  behaviors-file scope. REQUIRED before tighten is correct.
- **foreign BARE-ref flip** — --foreign-only only flipped 2-seg `Bluebook::Aggregate`
  refs. Bare `Aggregate.verb` refs (21 resolved, 0 ambiguous today) that are
  FOREIGN must also be qualified, or they break on tighten. Needs a foreign-aware
  `--resolve-bare` pass.
- **step 4 (TIGHTEN)** — drop the global fallback from resolve() : a short ref is
  local-ONLY, absent-local is an error. Homonyms structurally impossible. The
  dangerous step — do only after the two above, full gate, fresh head.
- **step 5 (events)** — full-FQN matching for FOREIGN event subscriptions.

## position-blindness (known tool limitation)
`fqns --rewrite` is quote-anchored, not position-aware — it matches ANY
"Bluebook::Aggregate.verb" string, including comment examples + data attribute
values. Phase 2 hit 2 comment lines (reverted by hand). A position-aware rewriter
(only dispatch-address keywords : dispatch/result_into/trigger/setup/tests/driven)
is the eventual clean tool. Always `git diff` review after running it.

## Risk
Dispatch core. Additive-first (step 1) is the safe entry. Gate hard between every
step. The behaviors corpus caught the folder-exact regression this session — trust it.
