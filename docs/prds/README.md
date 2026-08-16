# Runtime & parser bug-scrubbing: eight PRDs, sequenced

Scoped 2026-08-16, after a survey of what bug-hunting infrastructure already
exists for the Ruby runtime and the Rust parser (`lib/hecksagain/fuzzing/`,
`spec/adapters/query_agreement_spec.rb`, `bin/model_check`, the parser
parity/coverage specs, `bin/fuzz`'s own shrinker). That survey is the "what's
already covered" baseline every PRD below cites against — none of these
duplicate an existing gate.

Same discipline as [`fuzzer-property-expansion-plan.md`](../fuzzer-property-expansion-plan.md):
read the real enforcement code before scoping, not just the symptom. One item
below (`01`) is not really a "build a check" PRD at all — it's a fix for a
bug someone already found and self-documented in a comment, never closed.
That moves first for the same reason the entity-identity collision moved
first in the fuzzer plan: it's not "add a test," it's "there's a hole."

## The eight

| # | PRD | Size | Blocked on |
|---|---|---|---|
| 1 | [`reaction-depth-race`](01-reaction-depth-race.md) — fix the known unguarded thread race + a general concurrent-dispatch stress test | small | nothing — ready now |
| 2 | [`numeric-boundary-coverage`](05-numeric-boundary-coverage.md) | small | nothing — ready now |
| 3 | [`fuzzer-real-adapters`](02-fuzzer-real-adapters.md) — run the whole property suite against Sqlite/Postgres, not just Memory | large | nothing — ready now |
| 4 | [`mutation-application-agreement`](03-mutation-application-agreement.md) | medium | benefits from #3, not blocked by it |
| 5 | [`rust-conformance-fuzzing`](04-rust-conformance-fuzzing.md) — feed generated sequences through the Ruby/Rust differential harness | medium | nothing — ready now |
| 6 | [`parser-adversarial-fuzzing`](06-parser-adversarial-fuzzing.md) — `cargo-fuzz` against the Rust parser | medium | nothing — ready now |
| 7 | [`ruby-mutation-testing`](07-ruby-mutation-testing.md) | medium | nothing — ready now, but sequenced late on purpose |
| 8 | [`coverage-guided-fuzzing`](08-coverage-guided-fuzzing.md) | large | genuinely benefits from #3 and #5 landing first |

(Numbering above is priority order, the order I'd pick work in with one
worker. The wave plan below is execution order once more than one worker is
available — the two aren't the same thing, the same distinction
[`dsl-work-slices.md`](../dsl-work-slices.md) draws between *dependency*
order and *collision* order.)

## Real dependencies (not just priority)

Only two genuine sequencing constraints exist in this set — everything else
is priority, not blocking:

- **`08` coverage-guided-fuzzing** is technically buildable standalone, but
  its whole value proposition is "guide `bin/fuzz` toward code coverage it
  isn't reaching yet" — that payoff is much bigger once `bin/fuzz` already
  reaches real-adapter code paths (`03`) and the Rust runtime (`05`).
  Building it first would mean guiding generation toward surface area
  (Memory-only, Ruby-only) that's already the best-covered part of the
  system. Sequence it after `03` and `05`, not because of a hard technical
  block.
- **`04` mutation-application-agreement** can be built two ways: a narrow,
  hand-written differential spec today (`query_agreement_spec.rb`'s own
  shape, just for mutations instead of query comparators — fast, ships
  independently), or as a near-free extension once `03`'s fuzzer-against-
  real-adapters infrastructure exists (the property layer would just need
  one more comparison: does adapter A's stored result match adapter B's).
  Either order works; its own PRD describes both paths.

Everything else — `01`, `02`, `05`, `06`, `07` — has zero prerequisites
among this set and zero prerequisites on the two above. Start any of them
immediately.

## Collision map (same reason `dsl-work-slices.md` tracks this separately from dependencies)

None of these seriously collide. The rough file footprint per PRD:

- `01` — `lib/hecksagain/runtime/dispatcher.rb`, `lib/hecksagain/runtime/registry.rb`, one new concurrency spec.
- `02` — `lib/hecksagain/fuzzing/value_generator.rb`, `lib/hecksagain/fuzzing/invalid_value_generator.rb`, existing growth specs.
- `03` — `lib/hecksagain/fuzzing/isolated_boot.rb`, `lib/hecksagain/fuzzing/sequence_generator.rb`, `spec/fuzzing/properties_spec.rb`.
- `04` — a new `spec/adapters/mutation_agreement_spec.rb` (hand-written path) or `lib/hecksagain/fuzzing/properties.rb` (fuzzer-extension path, only if built after `03`).
- `05` — `spec/rust_conformance_spec.rb`, possibly a new `bin/` script bridging `SequenceGenerator` output to the Rust conformance binary.
- `06` — `rust/` only (a new `fuzz/` crate under `rust/parser/` or similar). Zero Ruby-side files.
- `07` — a new `Gemfile` entry + config, scoped narrowly to `lib/hecksagain/runtime/command_interpreter.rb` first.
- `08` — `bin/fuzz` itself, plus whatever coverage-instrumentation hook it needs.

The only real overlap is `03` and `05` both touching the fuzzer's own
boot/replay path at a glance (`isolated_boot.rb`/`replay.rb` for `03`,
`spec/rust_conformance_spec.rb` for `05`) — different concerns (adapter
binding vs. a Rust subprocess bridge), different files in practice, but if
one worker is doing both, do `03` first — `05`'s bridge script is easier to
write once `03` has already proven what a non-Memory-bound generated
sequence looks like end to end.

## Wave plan (what actually runs in parallel)

**Wave 0 — start immediately, one worktree each, true parallel:**
`01`, `02`, `05`, `06`, `07`. Five independent workers, zero shared files,
zero shared context needed between them. (`07`'s Gemfile addition is the
only one touching a file every other worktree also touches indirectly via
`bundle install` — land it first within Wave 0 if that's a concern, or just
let whichever merges first win and the rest rebase; it's a one-line Gemfile
diff, not a real conflict.)

**Wave 0, if capacity allows a sixth worker:** `03` can start immediately
too — it has no prerequisites, it's just the largest single PRD in the set,
worth a dedicated, unhurried worker rather than splitting attention.

**Wave 1 — after `03` lands:** `04` (if taking the fuzzer-extension path
rather than building it standalone in Wave 0) is now cheaper to build.

**Wave 2 — after `03` and `05` both land:** `08`. Not a hard technical
block, a "why guide generation toward the least-covered system first"
sequencing call.

## What ships from this, independent of order

Same as the fuzzer plan's own closing note: scoping each of these already
surfaced one confirmed, unfixed bug (`01`'s own subject) before any code
changed. That's the expected shape of this kind of work, not a bonus —
reading the real enforcement code closely enough to scope a check honestly
tends to find something.
