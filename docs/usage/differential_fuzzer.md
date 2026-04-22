# Differential runtime fuzzer (i30)

Generate random legal bluebooks + random command sequences from a u64 seed,
dispatch against both the Ruby and Rust runtimes, compare final `.heki`
state. Catches cascade-state-propagation bugs the parser-level parity
suite misses.

## Running

```bash
# Default: 200 seeds × ~0.05s = ~10s locally
rake parity:fuzz

# Reproduce one specific seed (writes failure artifact on divergence)
ruby -Ilib spec/parity/fuzz/fuzz_test.rb --seed 228

# Sweep 2000 seeds (nightly CI scale — ~45s)
ruby -Ilib spec/parity/fuzz/fuzz_test.rb --count 2000

# Explicit range + budget
ruby -Ilib spec/parity/fuzz/fuzz_test.rb --start 500 --count 100 --budget-seconds 60

# Via rake
FUZZ_ARGS="--seed 228 --verbose" rake parity:fuzz
```

## When divergence fires

Each divergent seed gets a full failure artifact under
`spec/parity/fuzz/failures/<seed>/`:

- `FuzzSeed<N>.bluebook` — the generated domain
- `program.json` — the seed + command sequence
- `reason.txt` — agree/diverge reason string
- `diff.txt` — side-by-side canonical JSON for Ruby vs Rust
- `ruby_heki/` and `rust_heki/` — forensic copies of both `.heki` trees

Two ways to handle a divergence:

1. Fix it. The artifact reproduces the bug — once fixed, re-run
   `--seed <N>` and confirm it agrees, then remove any entry for it
   from `spec/parity/fuzz/known_drift_fuzz.txt`.

2. Document it. Add one line to `known_drift_fuzz.txt`:

       seed=<N>  # brief reason

   The seed then prints `⚠` and stops failing CI until it's fixed.

## Seed 1 is reserved

Seed 1 is a hand-tuned cascade shape that reproduces the sleep-regression
class (the `next_id` bug in `lib/hecks/behaviors/state_resolver.rb`).
It's the must-catch gate against generator regressions: a stub that
always produces a legal-but-trivial domain would pass every other seed
and silently let real drift back in.

Revert the `next_id` fix and seed 1 diverges with 5/5 `GivenFailed`
errors on the Ruby side.

## What the fuzzer does *not* do (v1)

- No time-valued attributes — wall-clock is non-deterministic
- No LLM adapters — non-deterministic
- No dynamic module loading
- No lifecycles in generated bluebooks — Rust enforces `from:` guards
  strictly, Ruby doesn't; noise dominated real signal. Re-enable in v2.
- No shrinker — failure artifacts are full-size; manual reduction
  stands in for automated shrinking for now.
