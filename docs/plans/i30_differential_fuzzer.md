# i30 — Differential runtime fuzzer

Source: inbox `i30` + plan by Agent a2e770ed on 2026-04-22.

## Goal

Make the Ruby↔Rust parity contract **load-bearing instead of nominal**. Generate random legal bluebooks + random command sequences, dispatch against both runtimes, compare final heki state. The existing parity suite (`spec/parity/*.rb`) tests *parse* + *single dispatch*; the fuzzer tests *cascade state propagation* — exactly the class of bug the sleep-regression (fixed in `state_resolver.rb#next_id` earlier) represented.

## Architecture

New directory `spec/parity/fuzz/`:

- `generator.rb` — random legal bluebook + fixture + command sequence from a u64 seed
- `runner.rb` — isolated temp-dir orchestration, dispatches against both runtimes
- `comparator.rb` — heki reader + canonicalizer + diff
- `fuzz_test.rb` — driver (entry point, seed loop, budget, drift writer)

## Generator constraints — "legal bluebook"

- 1–3 aggregates
- 2–5 attributes per aggregate from fixed type alphabet (String, Integer, Float, Boolean, list_of(String), list_of(Integer))
- 0–1 lifecycle per aggregate (2–4 transitions)
- 1–4 commands per aggregate with optional `given`, `then_set`, `emits`
- 0–2 cross-aggregate policies (cascade lever)
- Self-reference flag on 50% of non-Create* commands (exercises both `StateResolver` paths)

Generator **enforces legality**, not fuzzes it:
- Unique `emits` names within bluebook
- Every policy's `on_event` matches some command's `emits`
- Every `given` references a declared attribute
- Create-prefix commands are the only entry point for new self-referenced entities (respects `StateResolver::CREATE_PREFIXES`)

**Bias toward cascade shapes** — singleton aggregates + integer fields + `given` predicates + cascading policies. Ensures sleep-regression-class appears ~1 in 20 seeds.

## Comparison strategy

**NOT byte-for-byte on heki files.** Zlib determinism across library versions is a red herring. Instead: **canonical JSON after stripping volatile fields + sorting keys + normalizing numerics.**

1. Run program against each runtime in isolated temp dir
2. `heki::read` each `.heki` store (needs Ruby heki reader — see §prereq)
3. Canonicalize: strip `id`/`created_at`/`updated_at`/`archived_at`, sort keys, normalize `1` vs `1.0` per declared type
4. `JSON.generate` both → byte-for-byte compare

## Seed management

- Single u64 seed drives all randomness (one `Random.new(seed)` instance)
- **Seed 1 reserved**: hand-tuned cascade shape that reproduces the sleep-regression class. Must-catch gate against generator regressions.
- CLI: `ruby -Ilib spec/parity/fuzz/fuzz_test.rb [--seed N] [--count N] [--budget-seconds S]`
- Local default: 200 seeds × 0.4s ≈ 80s (nightly opt-in)
- CI nightly: 2000 seeds ≈ 13min

## Failure artifacts

On divergence, write minimal failing case to `spec/parity/fuzz/failures/<seed>/`:
- the generated bluebook
- the generated program
- both heki stores
- the canonical JSON diff

No shrinker in v1 — just keep the full failing case for manual reduction.

## Known-drift file

`spec/parity/fuzz/known_drift_fuzz.txt` keyed by seed (not path — paths are ephemeral). Format: `seed=N  # reason` or `seed=N shape=<hash>  # reason` for covering multiple seeds with same shape.

## Prerequisite

**Ruby-side heki reader (~40 LoC).** `Zlib::Inflate` + `JSON.parse` over the `"HEKI"`-magic format. Ruby writes via ORM adapters today — the reader is fuzzer-specific. See `lib/hecks/heki/reader.rb` sketch in the plan. Previous attempt (Agent adfc07af) stalled on binary-dep design; redo with cleaner prompt.

## Integration with existing parity suite

Fuzzer is a **separate target**, NOT invoked by pre-commit:
- Pre-commit stays fast + deterministic (113/113 synthetic + real corpus)
- Fuzz is nightly CI + on-demand via `rake parity:fuzz`

Existing `known_drift.txt` / `fixtures_known_drift.txt` / `behaviors_known_drift.txt` untouched.

## Commit sequence (6)

1. `fuzz: add generator for legal synthetic bluebooks`
2. `fuzz: add heki reader + state canonicalizer`
3. `fuzz: add runner that dispatches program against both runtimes`
4. `fuzz: comparator + fuzz_test.rb driver with seed 1 cascade regression`
5. `fuzz: wire rake parity:fuzz + document known_drift_fuzz.txt`
6. `ci: nightly fuzz job`

## LoC estimate

~710 total (under Ilya's "one week of work" estimate, leaves headroom for shrinker).

## Risks

- **Wall-clock in runtime** — if either runtime uses `now()` inside a `given` or mutation, comparator produces false positives. **Mitigation**: generator excludes time-valued attributes in v1. Documented as deliberate restriction.
- **Ruby heki reader doesn't exist yet.** 40 LoC, trivial, but flag as prereq.
- **Seed 1 is a cheat that proves contract-catches-the-known-regression.** Statistical coverage of cascade shapes rests on seeds 2–N. Acceptable for v1. v2 = coverage-guided fuzzing.
