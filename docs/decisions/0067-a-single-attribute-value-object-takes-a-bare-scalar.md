# A single-attribute value object takes a bare scalar, and no new syntax is added for it

**Status:** Accepted — implemented in 2.8.0. The behavior already shipped in both runtimes. The live confirmation on both runtimes and the cross-runtime pin fixture are done; the documentation sweep covered the README and the pizzas behaviors file, and the guides still use the explicit spelling in places.

**Date:** 2026-09-27

## Context

Calls such as `name: { value: "Margherita" }` look verbose for a value object with one field. A ticket (`docs/wayfinder/review-followup/tickets/09-value-object-coercion.md`) asked for an opt-in declared coercion, on the premise that the Rust runtime refuses a bare scalar there on purpose. That premise came from an outside review and does not hold. Both runtimes already accept the bare form for a single-field value object; the refusal exists only for a value object with more than one field. No ADR says otherwise.

- **Ruby.** `Value::Coercion#for_attribute` (`lib/hecks/runtime/value/coercion.rb:112`) wraps a bare scalar into the sole field when the value object has exactly one attribute (`:387`). Anything else that is not an object raises `TypeMismatch` (`:389`), worded by the `value_object_shape` entry in `lib/hecks/vocabulary.rb:300`.
- **Rust.** `Json::coerce_single_field` (`rust/src/kernel/json.rs:307`) wraps a non-object, and `expect_value_object_shape` (`:333`) refuses a multi-field type with the same wording. Both generators emit the choice (`rust/project/json_codec.rb:115-128,251` and `rust/codegen/src/json_codec.rs:107-124,226`). The origin is commit `a144829f`.
- **Documented and tested.** `docs/implemented/reference/value_object.md:66-75` and `docs/implemented/guides/aggregates-and-value-objects.md:521-538` describe the rule. In Ruby, `spec/scalar_value_object_spec.rb:151-190` covers it. No cross-runtime fixture in `spec/corpus/rust_conformance/` pins it; only that spec, the fuzzer and codegen parity do.
- **Where the verbosity really is.** The docs and examples still use the explicit spelling: about 7 README lines, the pizzas behaviors file, banking, and many lines across the guides and reference. The UI schema keeps `{value: ...}` as a wire shape by choice (`rust/host/src/ui_schema.rs:11-21`).

## Decision

1. **Close the ticket as already shipped and add no new syntax.**
2. **The standing rule.** Wherever a command or query argument is typed as a single-attribute value object, a bare scalar wraps into that sole field. A multi-field value object still refuses a non-object with the `value_object_shape` refusal. Both runtimes follow this rule, and a change to it in one is a change to both.
3. **Follow-ups.**
   - Confirm once, with one live bare-scalar call on each runtime, that both accept it. The research read code and specs but did not run a call.
   - Sweep `README.md`, `examples/pizzas/bluebook/pizzas.behaviors` and `examples/banking/bluebook` to the bare form, keeping `{ value: ... }` only where a document is teaching that shape.
   - Add a cross-runtime fixture under `spec/corpus/rust_conformance/` that pins single-field bare-scalar acceptance.

## Alternatives considered

- **A declaration on the value object,** a flag replacing the attribute-count test. It makes the intent explicit, but needs an IR flag, both runtimes and regenerated code, and is breaking unless the default stays "one field means yes", in which case it adds nothing today.
- **A per-attribute marker** (`bare: true`, like `optional:` and `default:`). The cheapest hook, but it must be repeated at each use. It is the first sketch to react to if the caveat below ever hurts.
- **A boundary-only projection at each entry point.** No IR or core change, but each entry point copies what the core already does, and the copies can drift from Ruby/Rust byte-identity.

## Consequences

- No IR, DSL or generator change. Every invariant check and the Ruby/Rust byte-identity stay as they are, because nothing about the coercion moves.
- The collapse is implicit and gated on attribute count. Adding a second field to a value object turns every existing bare call from accepted into `TypeMismatch`. A declared marker is left as a future option, to be built only if that ever hurts.
- Once the fixture lands, a runtime that stops accepting the bare form for a single field fails the shared corpus rather than only the Ruby spec.
- The record is corrected: the Rust runtime does not deliberately refuse a bare scalar here. That holds only for multi-field value objects.

## Open items

- Should the README keep `{ value: ... }` in one place for teaching, or show the bare form everywhere?
- Is the pin fixture wanted beyond the Ruby spec? The maintainer chose yes; it is listed above until it exists.
