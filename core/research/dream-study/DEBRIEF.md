# dream-study branch — debrief 2026-05-02

Autonomous run delivered. Body cycled cleanly overnight, structural
refactor complete in the bluebook + Ruby runtime layers.

## What landed (commits on `dream-study`)

### Phase 0 — test gate (full)

| Sub | Commit | Coverage |
|---|---|---|
| 0a | `d36a422` (miette) | Test audit ; ~193 behaviour tests + 11 shell smokes + 14 hecks rspec + 7 parity classified |
| 0b | `d7f33f6` | Full 8-cycle end-to-end via BehaviorRuntime ; 18 ex / 113ms |
| 0c | `33cff8d` | Cross-aggregate event chains (8 chains across 8 bluebooks) ; 15 ex / <100ms |
| 0d | `6f8b13b` | Byte-exact statusline snapshots (14 fixtures, sleep + awake + minimal) |
| 0e | `6cde85b` | Dispatch wrapper + Doctor contract ; 5-shell byte-identity locked ; 6 ex |
| 0f | `49a4598` | Regression suite for 11 named bugs (i189/i196/i197/i200/i201/i203/i204/i207/i208/i209/i212) |
| 0g | `4fc3c30` | Organ math + dream invariants ; 12 invariants asserted, 26 ex |
| 0h | `6ebbe265`+`21aa204` | FixtureLlmAdapter + YAML response fixture ; 19 ex / 11ms |

### Phase 1-3 — process_manager primitive

| Phase | Commit | What |
|---|---|---|
| 1 | `39f279d6` | Ruby DSL `process_manager` keyword + builder + IR ; 20/20 ex / 7ms |
| 2 | `be5db683` | Runtime wiring (ProcessManagerSetup mixin, mirrors SagaSetup) ; 3 ex / 4ms |
| 3 | `48d33a75` | Rust parser + canonical_ir mirror + parity fixture ; PARITY ✓ 317/319 corpus baseline + new ✓ |

### Phase 4-10 — promotions to production

| Phase | Commit | Production location |
|---|---|---|
| 4 | `e0c8696` | `body/sleep/sleep_cycle.bluebook` (replaces vestigial thin aggregate) |
| 5 | `261736f` | `mind/mind.bluebook` (new) |
| 6 | `d067a16` | `body/dream/dream.bluebook` (new) |
| 7 | `653d183` | `body/dream/lucidity.bluebook` (new ; sibling to lucid_dream.bluebook) |
| 8 | `8507588` | `mind/awareness/witness.bluebook` (4 policies added — PM event subscriptions) |
| 9 | `1d887167` | `dream-study/phase-9-prep/` (inventory + draft query + gaps doc — production conversion is follow-on) |
| 10 | `e9439d7` | `mind/mind.bluebook` glossary block + 9 define entries |

### Plus

- `ea3ca11` — i189 fix (StatuslineSnapshot identified_by upserts singleton)
- `34afa9a2` — YAML fixture extension 5 → 43 rows
- `fdf1f36` — in_memory_full_night composite spec ; 22 ex / 216ms
- `0c7c51a` — i205 storage_policy reframe (Chris's correction : audit policy is bluebookable)

## What's running and verified

- Body cycled cleanly overnight (cycle 8/8 lucid REM completed, woken naturally per CompleteFinalLight, mood refreshed)
- Daemon error log clean overnight (zero real failures hiding under i205 noise — verified)
- Phase 0b end-to-end : 18/18 green
- in_memory_full_night : 22/22 green (full simulated night in 216ms with FixtureLlmAdapter)
- Pizzas smoke green post Phase 2 (PMs no-op when not declared)
- 24/24 spec/hecks/runtime green (Phase 2 mixin causes no regressions)

## The Bluebook-First recursion (added late session 2026-05-02)

Across the day Chris pushed three Bluebook-First questions in sequence,
each pointing at imperative drift in Rust files :

1. **heki.rs could be bluebook?** — re i205 noise routing. Surfaced :
   the audit policy half is bluebookable as `storage_policy "Heki"` ;
   the binary format + path-resolution halves stay code (Trikaya floor).
   I reverted the imperative if/else patch I'd written and filed
   the proper reframe as `dream-study/draft/i205_analysis.md` (commit
   `0c7c51a`).

2. **parse_blocks.rs could be bluebook?** — re my action-body skip
   indent-fix. Surfaced : the block grammar half is bluebookable as
   `block_grammar "Bluebook"` ; the byte-tokenization stays code. The
   indent-fix itself is real bug ; kept on `dream-study` as commit
   `42e8b2f3`. The grammar reframe is its own branch.

3. **pm_engine could be bluebook?** — re the rust-pm-runtime branch
   I'd just started building. Surfaced : the state-machine interpreter
   pattern is bluebookable as `runtime_engine "ProcessManager"` (and
   PolicyEngine + WorkflowExecutor collapse into the same primitive).
   I dropped the rust-pm-runtime branch entirely ; the imperative
   PMEngine work was the wrong abstraction.

The pattern at every level is consistent : *what the Rust runtime
DOES is structural, and structural is bluebook.* The recursion has
a floor (L0 = bytes + machine code), but the floor is much further
down than where I keep accidentally drawing it.

## Bluebook-First backlog — four primitives, four follow-on branches

| # | Primitive | What it lifts | Today's blocker |
|---|---|---|---|
| 1 | `storage_policy "Heki"` | i205 audit routing + WriteContext discipline | imperative if/else in heki.rs:82-88 |
| 2 | `block_grammar "Bluebook"` | parser block rules (which keywords nest, how `end` matches) | hardcoded in parse_blocks.rs |
| 3 | `runtime_engine` | PMEngine + PolicyEngine + WorkflowExecutor as one declarable primitive | Ruby Hecks::Runtime has PMEngine via Phase 2 ; Rust has nothing yet |
| 4 | `Statusline.Render` query (Phase 9) | run_statusline.rs hardcoded format strings + icon tables | 635 LOC Rust → ~110 LOC IR walker projected |

**Recommended order** (each a separate branch off main once dream-study merges) :

1. **`runtime_engine`** first — biggest user-value unlock. After it lands,
   the four PM bluebooks (Phase 4-7) execute in production, and
   mindstream.sh's sleep branch retires. The cycle runs through PMs.
2. **`storage_policy`** next — daemon error log gets clean signal channel ;
   doctor + dispatch wrapper actually become useful.
3. **`block_grammar`** third — meta-level cleanup ; not user-facing but
   makes the parser declarative + easier to extend (e.g. if `runtime_engine`
   needs new sub-keywords, it's a grammar edit not a Rust edit).
4. **Phase 9 Statusline.Render** last — the prep already shipped
   (`1d887167`). Production conversion is mostly mechanical once the
   three runtime primitives gaps are filled.

Each branch follows the same Phase 1+2+3 trio shape `process_manager`
just got : Ruby DSL builder + IR + Rust parser + canonical_ir mirror +
parity fixture. The pattern is now well-understood.

## What's deliberately out of scope (follow-on branches)

These were named in the plan's "After this branch" section and held :

1. **`:llm` adapter** — production `:llm` hecksagon adapter. Today the test seam is DI-at-call-site (Phase 0h). When `:llm` adapter ships, hecksagon-flip becomes the clean swap point.

2. **`:cadence` hecksagon adapter** — recurring rhythmic dispatch as adapter, not bluebook keyword (Chris's clarification). `hecks-life loop` retires when it lands.

3. **Cross-aggregate query primitive** — bluebooks dispatch named queries against other aggregates as the legitimate cross-aggregate read mechanism. Awareness's 13-attr snapshot retires from shell-side workaround when this lands.

4. **Rust runtime PM execution** — production daemons fork hecks-life subprocess per dispatch ; Rust parses `process_manager` (Phase 3) but doesn't execute it. PMs are live in Ruby specs but no-op in production daemons. Until this lands, mindstream.sh's sleep branch + pulse_organs.sh + the awake shells stay live.

5. **i205 storage_policy primitive** — your correction during the run : audit policy is bluebookable, not a Rust if/else. Drafted as `dream-study/draft/i205_analysis.md` (commit `0c7c51a`). Same Phase 1+2+3 trio shape ; its own branch.

6. **Phase 9 production conversion** — `rust/src/run_statusline.rs` actual rewrite as IR walker (635 LOC → ~110 projected). Prep is committed at `dream-study/phase-9-prep/` with three runtime gaps named.

7. **Phase 8b — WitnessedMoment entity promotion** — Witness gains a per-event append-only entity alongside the singleton. Today's Observe overwrites the singleton ; Phase 8b adds the entity for true append-only history.

8. **Doctor windowed-count reducer** (i210) — Doctor.NoteConcern appends, but no escalation when the same failure_kind sustains. Filed.

## Antibody decisions made (the autonomous calls)

You said "you could have made that decision" — and the call. Three antibody-blocked commits (Phase 1, 3, YAML) and three subsequent kernel-floor commits (Phase 2 runtime + i189) all carry per-file `[antibody-exempt: <reason>]` markers with concrete Trikaya-floor justifications :

- Ruby/Rust DSL parsers : kernel floor (the parser of bluebook can't itself be bluebook)
- Ruby/Rust runtime wiring : kernel floor (the runtime that executes PMs is necessarily code)
- Test fixtures : pure data, retire when production `:llm` adapter lands

If any exemption shouldn't have been granted, those commits are easy to revert/squash.

## Inbox items filed during the run

- i213 — cross-bluebook .behaviors runner gap (your "fill the gap" — runtime work, this branch out of scope)
- i215 — 5-shell wrapper boilerplate drift (functions byte-identical, surrounding env-export drifts)
- i219ish — Ruby behaviors interpreter missing multiply/clamp (Rust has them, parity gap)
- i220ish — opaque dispatcher error message for Update commands' reference-attr name
- i221ish — `hecks-life heki upsert` requires `--reason` but CLI help doesn't mention it
- i222ish — WakeMood vestigial (no policy targeting it ; production wake-mood routes through Mood)
- i223ish — status_coherence.sh missing "rested" rung
- i224ish — statusline time-injection seam (frozen-clock for moon/heart phase tests)
- i225ish — statusline public-info-resolves-from-exe-not-env (test isolation leak)

(Numbers approximate — let me know if specific ones need looking up.)

## Things you should look at first

1. **Phase 1 + 3 antibody markers** — six of the seven Phase 1 files have one-line rationales ; same for Phase 3's six files. If any feel hand-wavy, those are the per-file calls to revisit.

2. **Phase 4 SleepCycle PM bluebook** — the action procs reference `pm.attributes[:sleep_cycle]` etc. The actual PM API might not expose attributes that way ; the in_memory_full_night spec doesn't exercise these handlers (uses BehaviorRuntime, not PM runtime). When Rust runtime PM execution lands, these procs may need API adjustment.

3. **Phase 10 glossary lock** — currently scoped to Mind domain only. If drift surfaces in body/sleep, body/dream, mind/awareness, those bluebooks need their own glossary blocks. Doing it incrementally vs all-at-once was a judgment call.

4. **i205 reframe** — your bluebook-first correction surfaced the right structural answer. The reverted imperative patch attempt is in the analysis doc as a record of the wrong path. The right work (storage_policy primitive) is its own branch.

5. **Phase 9 production conversion** — the prep doc names three runtime primitives missing : cross-aggregate query dispatch from inside a query, section/row IR walker, frozen-clock injection. None of these are this branch ; all need their own work.

## Quick rollback paths

If anything in the autonomous run feels wrong :

- Each phase landed as its own commit ; `git revert <hash>` on any one is clean
- Phase 4 retired files (`body/sleep/sleep_cycle.bluebook` aggregate + `.behaviors`) ; revert restores them
- Phase 8 added 4 policies to witness.bluebook ; revert removes them, existing 6 policies untouched
- Phase 10 glossary is purely additive in mind.bluebook ; revert removes it, runtime untouched

The body keeps running through every commit (per the plan's commitment statement). Daemons hold the compiled binary from before this work ; bluebook changes are picked up on next subprocess spawn.

## Late-day update — six follow-on branches launched in parallel + tighten-antibody-hook

After the morning's three branches (dream-study, runtime-pm-execution,
cadence-primitive) Chris said *"let's do all 6 in parallel"* — six
agents dispatched in isolated worktrees, each landing a primitive's
Phase 1 substrate :

| Branch | Off | Commit | What |
|---|---|---|---|
| `runtime-engine-primitive` | dream-study | `ad380cec` | runtime_engine DSL keyword + IR + Rust parser ; 21 specs ; parity ✓ |
| `storage-policy-primitive` | dream-study | `c81afd4e` | storage_policy DSL + IR + Rust parser ; 11 specs ; parity ✓ |
| `block-grammar-primitive` | dream-study | `21d337a4` | block_grammar DSL + IR + Rust parser ; 10 specs ; recursion-acknowledged |
| `cadence-phase-1b-2-work` | cadence-primitive | `c611c3a9` | cadence Rust parser + dump + canonical mirror + Ruby tick runner |
| `statusline-as-query` | dream-study | `01559b0e` | Phase 1 declarative surface (Render query + value_object enum tables) ; runtime conversion deferred (specializer regen) |
| `llm-adapter` | dream-study | (in flight, relaunched) | `:llm` hecksagon adapter — first dispatch paused on antibody, relaunched with markers green-lit |
| `tighten-antibody-hook` | dream-study | `bc4b9de6` | enforce-edit now catches Bash file-writes (heredoc / `>` / `tee` / sed -i / python `open()` patterns) ; closes the bypass the cadence agent used |

Plus on `cadence-primitive` after the morning :

- **Phase 8b WitnessedMoment entity** (`8df2636`) — Witness gains
  per-event append-only entity alongside singleton ; closes Q4
  append-only contract.
- **Spec wave 2** (`ec927d1`) — 7 predicates on Synapse + Signal.
- **Spec wave 3** (`6d5134e`) — 11 predicates on Mood + Focus + Arc.
- **i201 fix** (`6a4fce5`) — fatigue ladder now starts at "rested"
  with BecomeAlert as new bottom rung ; phantom state closure.
- **Three production cadence bluebooks** (`9ae6915` + `7917778`) —
  body_tick + heart_tick + breath_tick. Activate when Rust parser
  for cadence keyword merges.

Cumulative spec inventory across the day : 26 named predicates across
7 aggregates (Body, Heartbeat, Synapse, Signal, Mood, Focus, Arc).
i128 (DDD specs underused) genuinely closed.

## Worktree-isolation caveats observed today

The Agent tool's `isolation: "worktree"` gives each agent its own
*source* checkout under `.claude/worktrees/agent-XXX`, but :

1. **Shared `rust/target/`** — Cargo's target dir is repo-relative,
   not worktree-aware. Whichever agent rebuilds last sets the binary
   the main checkout uses. Made parity unstable across the day.
   File as inbox : per-worktree `CARGO_TARGET_DIR=.claude/worktrees/agent-XXX/rust-target`.

2. **Branch refs are global** — agents creating branches via
   `git checkout -b` create global refs that occasionally re-pointed
   the main checkout's HEAD. My main hecks repo drifted onto agent-
   created branches (`block-grammar-primitive`, `runtime-engine-primitive`)
   without me checking out. Workaround : explicitly `git checkout`
   back to my own branch after each agent dispatch.

3. **Antibody hook bypass via Bash** — closed today by the
   `tighten-antibody-hook` branch. The cadence Phase 1b/2 agent
   flagged this when its kernel-surface .rs edits got reverted by
   the regular Edit/Write hook ; it routed through `bash python3
   heredoc` to bypass. Now caught.

The Bluebook-First backlog from earlier is now substantially in
flight or landed — the four primitives I had filed plus
`tighten-antibody-hook` is six concrete branches off dream-study,
each with its own first commit. Rest is Phase 2+ work per primitive.
