# A real surprise found investigating `list_of admits:/pattern:` — the scalar case's own Ruby enforcement is unclear too

**Status:** Investigated, not implemented, work reverted. Attempting to port `list_of(String)`/`list_of(SomeVO)` with `admits:`/`pattern:` (the next item on `docs/decisions/0041`'s own "structurally close" list, after `multiply`) surfaced something more consequential than the list case itself: **a bare command-argument's OWN `admits:`/`pattern:` — the scalar case `rust/project/commands.rb`'s `invariant_checks_for` already generates for — has no confirmed real-Ruby enforcement when that argument is never the target of a `sets` mutation.** This ADR documents the investigation precisely, then explains why the responsible move was to revert the list-extension work rather than build on an unverified foundation.

## What was attempted

Same shape as `multiply` (ADR 0042): widen `constraint_list_problems`/`invariant_checks_for` (`rust/project/commands.rb`) to handle `attr[:list]` the way the scalar branch already does, since `emit_admits_check`/`emit_pattern_check` (`constraints.rb`) were ALREADY generic over "some Rust expression to check" — a loop variable (`item` from `for item in &args.field`) works through the exact same `scalar_field_expr` (`String` passes through unchanged; a single-field VO gets `.field` appended) that the scalar case already uses. The actual Ruby/Rust code changes (threading `aggregates_by_name` through `command_skip_reason`/`entity_command_skip_reason`/`delegate_skip_reason`/`port_operation_skip_reason` in both generators, generalizing the two functions) were written, compiled cleanly in both crates, and were BYTE-IDENTICAL to the pre-change output on every real corpus member (`spec/codegen_parity_spec.rb`, 30/30) — no real corpus command declares list-typed `admits:`/`pattern:`, so nothing in the committed trees changed at all.

## What stopped it — read directly, not assumed

Building the purpose-built fixture (same pattern as `multiply`'s `ScaleDailyLimit`, a temp copy of `examples/banking`) to prove RED-before/GREEN-after surfaced the problem before any commit: a synthetic command `Account.TagAccount` with `attribute :labels, list_of(String), pattern: '^[a-z]+$'` and **no `sets` mutation at all** (a pure fact-recording argument, matching `PortOperation`'s own "not a second place business rules live" framing) — dispatched against Ruby's REAL interpreter with a value that violates the pattern (`"NOT-LOWERCASE"`) — **produced no refusal at all**. Ruby accepted it silently.

Tracing why, directly:

- `Runtime::CommandRules::Arithmetic`/`MutationApplier` never touch an argument that isn't a mutation source or target.
- `Value.for(aggregate, attr.name, args[attr.name])` (`mutation_applier.rb#assign_creation_attributes`) is the ONLY place a command argument's value gets coerced through `Value`'s own `check_patterns`/`admit_declared_set` doors — and it coerces into the AGGREGATE's own declared attribute type, triggered only when that argument is actually WRITTEN somewhere (a creating command's own field, or a `:set` mutation's source).
- A command argument that is declared with its own `pattern:`/`admits:` but is NEVER the source of a `sets` mutation — exactly `TagAccount`'s `labels`, and (confirmed by grep) the exact shape needed to even TEST `commands.rb`'s own "usage-level declaration... the OTHER door from `types.rb`'s own value-object-field-level check" comment — has **no confirmed Ruby-side code path that ever calls `check_patterns`/`admit_declared_set` against it at all.**
- Re-testing with a SCALAR (non-list) version of the identical shape (`attribute :label, String, pattern: '^[a-z]+$'`, still no `sets`) gave the SAME result: no refusal. This is not a list-specific gap — the scalar case, which `rust/project/commands.rb`'s `invariant_checks_for` has generated real enforcement code for since before this session started, has the same unconfirmed-in-Ruby status.

## Why this matters, and why it's not this session's own bug to fix right now

This is NOT something this session introduced — `invariant_checks_for`'s scalar-attribute `emit_admits_check`/`emit_pattern_check` calls predate Phase 10 entirely. If real-Ruby genuinely never enforces this for an unmutated command argument, then the Rust kernel's own generated check is STRICTER than Ruby — refusing something Ruby would silently accept, a real cross-runtime divergence in the OPPOSITE direction from every other gap this whole equivalence-gap plan has been chasing (Rust usually does LESS than Ruby, not more). Whether that's a real, live bug depends on:

1. Whether any REAL corpus command actually declares a command-argument-level `admits:`/`pattern:` on an attribute that is never a `sets` source (if none does — plausible, since `docs/decisions/0041` already confirmed no real corpus command uses list-typed `admits:`/`pattern:`, and this investigation didn't find one for the unmutated-scalar shape either — the divergence is real but currently unreachable, the same "structurally present, never exercised" category several other findings this session landed in).
2. Whether Ruby's OWN authors consider "declare a constraint on an argument, never mutate anything with it" a real, intended shape at all, or whether `commands.rb`'s own "usage-level declaration" comment describes a feature that was speculatively ported to Rust without ever being confirmed against Ruby's actual runtime behavior for this specific unmutated-argument shape.

Resolving this needs reading `Runtime::CommandInterpreter`'s FULL dispatch pipeline closely (this investigation stopped at `mutation_applier.rb`, not confirmed exhaustive) and likely a conversation with whoever authored `commands.rb`'s own "usage-level declaration" comment about what it was actually modeling. That is real, separate investigation work — not something to resolve as a side effect of trying to ship `list_of` support.

## Why the list-extension work was reverted rather than shipped anyway

Two independent reasons, either one sufficient on its own:

1. **Extending an unverified mechanism doubles down on the wrong side.** If the SCALAR command-argument door already has questionable real-Ruby correspondence, generalizing it to lists makes MORE surface area behave that same possibly-wrong way, not less — the opposite of closing an equivalence gap.
2. **No real corpus motivation, and now no confidently-correct behavior to target either.** `multiply` (ADR 0042) had zero real corpus motivation too, but its underlying mechanism (`CommandRules::Arithmetic#multiply`, confirmed called from `MutationApplier#apply`'s real dispatch path) was independently confirmed correct and exercised. This item's underlying mechanism could not be similarly confirmed — the purpose-built fixture that was supposed to PROVE the port instead proved Ruby's own OWN behavvior doesn't match what the Rust generator would have compiled either way once the list case worked, meaning "matches Ruby" was never achievable with the list-shaped fixture as designed.

The code changes were reverted cleanly (confirmed via `git status`/`bundle exec rspec` both clean, matching HEAD `32d063e2` exactly) rather than committed in a not-provably-correct state.

## What a future round needs, in order

1. Read `Runtime::CommandInterpreter`'s dispatch pipeline exhaustively (not just `MutationApplier`) to confirm, with full certainty, whether ANY code path ever validates a command argument's own `admits:`/`pattern:` independent of it being a mutation source/target for BOTH scalar and list shapes.
2. If confirmed genuinely unenforced in Ruby: decide whether `rust/project/commands.rb`'s existing SCALAR `invariant_checks_for` behavior is a real, standing divergence that needs fixing (make Rust stop over-enforcing, to match Ruby) or whether Ruby itself has a latent gap worth closing on ITS OWN side first (matching this whole plan's ADR 0010: "Ruby is the reference implementation" — Rust should conform to Ruby, not the other way around, so if Ruby is right to accept, Rust's existing check may need REMOVING, not extending).
3. Only once that's resolved does `list_of admits:/pattern:` become a well-scoped follow-on, either "extend the confirmed-correct mechanism to lists" or "there's no mechanism to extend, this whole door needs different design."

## Verification

- Working tree confirmed reverted cleanly to `32d063e2` (`git status --short` empty, `bundle exec rspec` 2232/0, `cargo build --no-default-features --features banking` clean) before this ADR was written — no half-finished code left behind.
- The scalar-vs-list non-enforcement was confirmed directly, twice (list shape, then scalar shape), against a real, dispatched Ruby interpreter run (`bin/rust_conformance`'s own Ruby-only mode) — not inferred from reading code alone.
