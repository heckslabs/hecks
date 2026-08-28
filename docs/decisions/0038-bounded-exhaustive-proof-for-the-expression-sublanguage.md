# A real "proven for all inputs" claim, scoped to the expression sublanguage

**Status:** Shipped. `lib/hecks/fuzzing/bounded_exhaustive_expressions.rb` + `spec/bounded_exhaustive_expression_spec.rb`, in the default suite (no `io:`/`fuzzing:` tag — deterministic, ~2,300 cases, well under a second).

## The claim, precisely

For every well-typed expression the type-directed generator can build up to nesting depth 3 (Addition/Modulo nesting, dotted `Lookup` chains, `.all?`/`.any?`/`.none?`/`.find` block predicates nested inside each other), interpreting it through the real `Hecks::Bluebook::Expression::{Evaluator,Resolver}` pipeline never raises anything other than `EvaluationError` — the sublanguage's own real refusal vocabulary. That file's own header comment has the full design rationale (why type-directed rather than exhaustive-over-strings, exactly what "well-typed by construction" means, why this is provably NOT the same as "computes the right answer" — a second, independent oracle's job, same relationship `rust_conformance_fuzz_spec.rb` has to the fuzzer). Not restated here; read it before extending this generator.

This is the one place in the whole equivalence-gap plan a genuine "true for all inputs" claim (not sampling) is honest — the plan's own non-goals section is explicit that a full formal proof of the whole system is not achievable, and this doesn't attempt one. It's a real, bounded, checkable claim about exactly one finite-grammar, side-effect-free sublanguage: `given`/`invariant`/`ensures` predicate bodies.

## What it found, immediately, on first real use

Four real, previously-undiscovered parsing bugs, all confirmed to have zero real-corpus precedent (checked directly, all four) — exactly why this is its own technique, not a wider `bin/fuzz` seed count: sampling essentially never manufactures the specific nested/chained/bracketed shapes that triggered them.

1. **`Resolver#match_call`** (`.modulo`) — `expr.rindex(".modulo(")` found the innermost occurrence of a NESTED divisor (`0.modulo(amount.modulo(3))`), not the outermost. Fixed to try each occurrence left to right, keeping the first whose balanced-paren match reaches the string's end.
2. **The same fix, a second shape** — CHAINED calls (`x.modulo(a).modulo(b)`) needed the "try the next occurrence" half of that same fix; the leftmost-only version still failed on this shape.
3. **`Evaluator#match_include`** — the identical `rindex` mistake, for a `.include?` needle that itself contains another `.include?` call. Fixed identically, reusing `Resolver.matching_paren` directly rather than duplicating it.
4. **`[`/`]` never counted toward bracket depth** in `Evaluator#top_level_index` or `Resolver#split_addition` — both already tracked `(`/`)` and `{`/`}` (the second added for an earlier, real "block predicate's own operator split the whole expression" bug, `docs/audits/2026-08-10-main-bug-audit.md`'s own storehouse-kernel Phrase invariant) but never brackets, so an array literal containing its own top-level `+`/comparison (`[0, 1 + 1].all? { ... }`) mis-split the ENCLOSING expression the identical way. Fixed by adding `[`/`]` to both depth counters.

All four fixed at the source, with red-before/green-after regression tests in `spec/expression_spec.rb` (not just the generator's own pass/fail) — reverting the fix and re-running those specific tests reproduces each bug's exact failure signature directly.

## A methodological finding worth keeping: "no crash" is weaker than "no misparse"

All four bugs above manifested as a *refusal* (`EvaluationError`, "cannot resolve ...") on first encounter, not a raw crash — a silent misparse that happened to fail safe. A pure "did it crash" check would have missed every one of them. The generator's own second, narrower assertion — every `"cannot resolve"` refusal is itself a finding, because every name this generator ever references is declared, with a value, in its own `synthetic_state` — is what actually surfaced all four; a real fuzzer with deliberately-absent attributes couldn't use this same check (an absent attribute *should* refuse this way), but a generator that controls its entire vocabulary can and should.

A fifth, separate mistake was caught the same way but was a bug in the generator's OWN synthetic state, not in `Resolver`/`Evaluator`: an early version modeled a single-field Value Object as a plain `{value: X}` Hash, which `Resolver#unwrap_scalar`'s own guard (`respond_to?(:to_h) && !is_a?(Hash) && !is_a?(Array)`) deliberately does NOT unwrap (a real Hash has no single scalar to safely collapse to — only an object that *responds to* `#to_h` without *being* one, matching a real hydrated `Runtime::Value`, gets unwrapped). Fixed with a small `Struct`-based stand-in (`SingleFieldVO`) instead of a bare Hash.

## Precedence bugs that are the generator's own, not the resolver's

Two more mis-generations were found and fixed in the generator itself, never reaching `Resolver`/`Evaluator` as a real bug report: `Compare`/`Include`/`Or`/`And`/`Not` (Evaluator-level syntax) and `Addition` (`split_addition` runs before any trailing suffix's own regex) can never legally be the RECEIVER of a Resolver-level suffix call (`.to_s`, `.positive?`, `.modulo`'s own receiver side) — confirmed a real, permanent boundary of the grammar's own two-layer split (`Resolver.parse` has no knowledge of Evaluator-level operators at all, and never strips parentheses either), not a bug to fix in the resolver for a shape with zero real-corpus use. `resolver_boolean_leaves`/`resolver_numeric_leaves` are the generator's own restricted-safe subsets for exactly this reason — read their own comments before assuming `bounded(:boolean, ...)`/`bounded(:numeric, ...)` are safe to embed as a receiver anywhere new.

## What this does not claim

- Semantic correctness (the interpreter computing the right ANSWER, not just failing safe) — a second, independent oracle's job, not attempted here.
- Anything about depth 4+, or about constructs outside this generator's own type-directed rules (a genuinely new node type added to `Resolver`/`Evaluator` needs its own production rule added here before this claim covers it).
- Anything about the Rust port of this sublanguage — `rust/src/kernel/expr.rs` and friends have their own, separate correctness question, untouched by this phase.
