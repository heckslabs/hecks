# Restart — Memory-Default Rollout (2026-06-28)

Resume of a long arc: make persistence explicit and uniform so the runtime can
flip to **memory-as-default** safely. Two phases are committed; the root-cause
fix + miette wiring + the flip remain.

## Where the work lives
- **Worktree:** `/Users/christopheryoung/Projects/hecks/.claude/worktrees/memory-default-rollout` (branch `memory-default-rollout`). Release binary already built there: `rust/target/release/storehouse`.
- **Commits on that branch:**
  - `fdcb1d0cc` Phase 1 — structure conform (412 files → per-domain `bluebook/` folders, backend-neutral), Ruby `WorldBuilder` FQN-verb parity (retired the pizzas.world drift), `Vocabulary.Compile` trigger qualification (fixed 3 grammar cascade regressions).
  - `227822ad0` Phase 2 — a hexagon for every hecks domain (wire-all per root, **mirror current backend, 0 flips**, unwired 419→216), 25 non-pure hexagons hand-merged, removed the `catalog/Hecksagon` anti-pattern bluebook.
- **Other worktree:** `drop-heki-base-refs` (branch `worktree-drop-heki-base-refs`) — 2 commits: `~/.heki` reference cleanup + `.test.world` spec card. Not merged.
- **Miette repo** (`~/Projects/miette`): feature branch `cpu-spin/overfire-singleton-keying` was **merged to clean `main`** (6 commits, fast-forward). Local main is 6 ahead of `origin/main` (NOT pushed — Chris's call). One merged commit is relevant: `deploy(boot): boot-guard (single-live-writer)`.

## The mandate (Chris)
Every bluebook has a hexagon. **Nothing autowired. Memory is the default.** Conform to the Pizzas exemplar (`bluebook/` folders). **One standard** across hecks + miette. Everything callable through storehouse. All persistence at the OS data root via `:default`; nothing at `~/.heki` or `~/.hecks`.

## Done
- hecks: Phase 1 (structure) + Phase 2 (hexagon-per-domain, behavior-preserving). All gates green: behaviors 772/772, aggregate+world+hexagon parity, specializer goldens 35/35, **0 backend flips**.
- miette feature branch merged to clean main.

## Remaining (in order)
1. **Home-based store resolution + persistence-adapter extraction** — the ROOT-CAUSE fix; gates the flip. Design below.
2. **Miette wiring (#6)** — conform + wire ~126 bluebooks in `~/Projects/miette` + 11 in `~/Projects/miette_family` to one standard; reconcile duplicated data.
3. **Kernel flip — memory default** (eliminate the implicit Heki default). LAST step; gated on 1+2.
4. `.test.world` implementation (spec is on the `drop-heki-base-refs` branch).
5. Heki cleanup — stray/legacy `.heki` → OS data root or removed.
6. Remove 4 structure-only files — 3 umbrellas (`world/boot/boot`, `conductor/conductor`, `discipline/immune_system/immune_system` — 0 aggregates) + 1 spike (`spikes/persistence_resolution_evans`).
7. Anti-pattern sweep — other bluebooks that model imperative codegen (like `catalog/Hecksagon`) → convert to Ruby / remove.

## THE DESIGN — home-based store + adapter extraction (reverse-engineered, deferred)

**The bug:** two runtimes write the SAME aggregate to TWO chains.
- Miette's body (boots `~/Projects/miette`) resolves `:default` → `miette/` chain.
- The hecks runtime loads `~/Projects/miette` as an *additional corpus root*, so those aggregates inherit the host's single global `data_dir` → `hecks/` chain.
- Result (live store `~/Library/Application Support/Hecks/`): `miette_memory/memory.heki`, `vows/vow.heki`, `chris_workflow/model_tier.heki` exist in BOTH `hecks/` and `miette/` chains (identical — same recs+mtime); `transparency/narration_rule` only in `hecks/`.

**The fix:** an aggregate's store follows ITS OWN conception, not the dispatching runtime.
- Each aggregate carries `realm_path` (`rust/src/ir.rs:386`), stamped by `corpus_loader` (`rust/src/corpus_loader/mod.rs:245`) from `heki::folder_address` = realm (first segment under `~/Projects`, e.g. `miette`/`hecks`) + context (rest), formatted `"<realm>/<context>"` or `"<realm>"`.
- `boot_with_data_dir` (`rust/src/runtime/mod.rs` — HAND-WRITTEN, antibody-exempt kernel-floor, EDITABLE) builds every `LazyRepository` with the same global `data_dir`. Store path = `<data_dir>/<context_snake>/<aggregate_snake>.heki` (`rust/src/runtime/repository.rs` `new_with_context`).
- Make `data_dir` per-aggregate, derived from `realm_path`: `data_root().join(<realm>)` (else global fallback when `realm_path` is None — foreign/isolated roots).
- **CAUTION — double-context:** `realm_path` already = realm + context, but `new_with_context` appends context again. So set the per-aggregate dir to `data_root()/<realm-only>` and let `new_with_context` append context; OR pass the full chain and stop appending. Cross-check `heki::default_chain` (`heki.rs ~951`) — it already derives `data_root/<chain>` for the single-root `:default` case; the multi-root (additional-corpus-root) case is the gap.

**The arc framing (Chris):** this fix = extracting persistence as a clean ADAPTER out of the runtime core. `boot_with_data_dir` currently hardcodes persistence (global `data_dir` → Heki per aggregate). Moving store-resolution into the persistence adapter (per-aggregate, home-based) removes the impure edge from `mod`, which is what makes `runtime/mod.rs` **projectable** from `runtime_shape` (the self-hosting endpoint). Same treatment later for the other impure edges (payment, tts, dispatchers). Order: extract persistence adapter → mod loses persistence hardcoding → mod projectable.

**The data migration (before/with the flip):**
- `hecks/` and `miette/` copies are IDENTICAL where both exist → choosing the `miette/` chain loses nothing.
- Gaps: stores only in `hecks/` (e.g. `transparency/narration_rule`) must be COPIED to the `miette/` chain before pointing `:default` there — else relocation strands them.
- **Stores are frozen** (miette_memory 2026-05-30, vows 2026-04-28, model_tier 2026-04-30). CONFIRM the body is actually persisting (find the live write path) BEFORE reorganizing — the freeze may indicate the real path is elsewhere.

## Durable set (the 12 source-of-truth aggregates classified)
Heki (irreplaceable): `MietteMemory::Memory`, `Vows::Vow`, `Transparency::NarrationRule`, `Story::Story`, `Correspondence::Correspondent`, `Appeal::{Session,Project,Backlog}`, `NurseryCorpus::Corpus`, `TrainingExtraction::TrainingPair`, `ChrisWorkflow::ModelTier`, `ChrisAntiPatterns::AntiPattern`, `OutboundEvent::OutboundEvent`, `AgentDiscipline::AgentDiscipline`. The first 5 live in the **miette** repo (out of hecks scope) — they're the data-loss-critical ones the flip must not orphan. Rule: `persisted_by("Heki")` iff source-of-truth (not re-derivable); everything else Memory. Churn that LOOKS durable but is re-derived: `StatusBar::Mode` (389k, 1-value), `Storage::Repository` (141k, runtime bookkeeping rebuilt at boot), `ForwarderPoc::NewHome`.

## Gotchas / pre-commit gates (this repo)
- Pre-commit runs ALL of: companion-check (move `.fixtures`/`.behaviors` WITH the bluebook on a move — i112 lesson), aggregate parity, world parity, hecksagon parity, specializer goldens (need the release binary built), behaviors corpus (`storehouse test hecks_conception/aggregates`), antibody (non-bluebook files need `[antibody-exempt: <per-file reason>]` lines in the commit message — NEVER pre-empt; report and let Chris approve).
- Goldens need `rust/target/release/storehouse` (build: `cd rust && cargo build --release -p storehouse-cli`; lib is `rust/`, binary is the `cli` member).
- Parity = Ruby parser == Rust parser on the SAME file (canonical JSON diff). It is NOT about generation or runtime config.
- `.heki` is BINARY — use `storehouse heki count <file>`, never `wc -l`.
- Shell is `/bin/sh` (no `<()` process substitution; use temp files).
- Safety gate for any wiring change: `storehouse backends <root>` before+after, diff for Heki/Memory flips — must be ZERO.
- `codegen/` is RELEASED to a parallel agent — don't touch. `persistence_resolution.rs` + `boot_with_data_dir`-adjacent shapes are GENERATED from `codegen/runtime_shape` (edit the shape, not the `.rs`) — but `runtime/mod.rs` itself is currently hand-written.
- Every tool call routes through the storehouse door (`storehouse__dispatch` → `Tools::ShellTool.Bash` / `FileTool.*`).

## Verify-state quickrefs
- backend map: `rust/target/release/storehouse backends hecks_conception`
- behaviors: `storehouse test hecks_conception/aggregates`  (expect 772/772)
- parity: `ruby -Iruby parity/{parity,world_parity,hecksagon_parity}_test.rb`
- live store chains: `~/Library/Application Support/Hecks/{hecks,miette,plan}/`
- `~/.heki` is gone; `~/.hecks` holds only a stale `inbox/next.json` (no aggregate state).
