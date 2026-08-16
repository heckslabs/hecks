# PRD 08 — Coverage-guided fuzzing for `bin/fuzz`

**Status:** Not started. Lowest priority in this set, sequenced last on
purpose — see below.

## The problem

`bin/fuzz` is a real, working fuzzer with a real shrinker (repeatedly drops
whole steps, then individual step arguments, keeping only removals that
still reproduce the same failure signature) — but generation itself is pure
random draw (seed-indexed) through a domain-aware weighted picker, with no
feedback loop from code coverage back into what gets generated next. It
sweeps every `.bluebook` domain in the repo, which keeps it realistic, but
nothing steers it toward code paths it hasn't exercised yet.

## Why this is sequenced last

Coverage-guidance is only as valuable as the surface area worth guiding
toward. Today, `bin/fuzz` (via `IsolatedBoot`) only ever reaches Memory-
adapter, Ruby-only code paths — the same surface area `03`
(fuzzer-real-adapters) and `05` (rust-conformance-fuzzing) are about to
widen substantially. Building coverage-guidance before those land means
steering generation toward the *already best-covered* part of the system —
real payoff, but a smaller one than doing this after that surface area
exists. This is a sequencing call, not a technical dependency — nothing
stops this PRD from starting today, it's just less valuable to.

## Approach

1. Instrument `bin/fuzz`'s own generation loop with real code-coverage
   feedback — the mechanics depend on what's practical for Ruby (a
   `coverage`-stdlib-backed tracker keeping a running set of hit
   lines/branches across the whole run, informing the picker's own weights
   toward under-hit paths) versus what's practical if `03`/`05` have by
   then made the "which engine, which adapter" dimension part of what needs
   guiding too (coverage across TWO runtimes is a genuinely harder problem
   than coverage within one).
2. Start with a narrower, concrete goal rather than "general coverage
   guidance": pick one thing coverage data should demonstrably improve
   (e.g., "the fraction of declared `Command#mutations` ops exercised
   across a fixed seed budget goes up with guidance versus without") and
   measure it before/after, rather than shipping guidance and hoping it
   helps.
3. Keep the existing shrinker untouched — coverage-guidance changes what
   gets *generated*, not what happens once a failure is found.

## Acceptance criteria

- [ ] A measurable coverage metric (branch/line, or a domain-specific one
      like "fraction of declared mutation ops reached") demonstrably
      improves with guidance versus the current pure-random baseline, on
      the same seed budget.
- [ ] The existing shrinker (`bin/fuzz`'s own step/argument-dropping
      mechanism) is unaffected.
- [ ] Any new bug this surfaces (which is the actual point) gets its own
      fix, same as every other PRD in this set.

## Non-goals

- Replacing `bin/fuzz`'s existing weighted-picker generation entirely —
  coverage-guidance augments it, doesn't need to replace the domain-aware
  "act on what exists" weighting that already makes generated sequences
  realistic.
- Cross-runtime (Ruby + Rust) unified coverage guidance on day one — land
  Ruby-side guidance first, revisit whether the Rust side needs its own
  pass (likely closer to PRD 06's `cargo-fuzz` territory, which already
  does its own coverage-guided mutation internally) once this PRD's own
  value is proven.
