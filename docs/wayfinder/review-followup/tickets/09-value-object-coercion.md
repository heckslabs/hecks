---
type: prototype
status: closed
blocked_by: []
claimed_by:
---

# Value-object ergonomics: single-attribute coercion

## Question

Calls like `name: { value: "Margherita" }` are verbose for single-field value objects. The Rust
runtime refuses a bare scalar there on purpose. Sketch two or three opt-in, declared coercions
(a declaration on the value object, a per-attribute marker, a projection at the boundary) as
rough before/after snippets to react to, and say which keeps every invariant check and the
Ruby/Rust byte-identity. Decide whether to pursue one.

## Prep (not a decision)

Gathered by a read-only agent. **The ticket's premise is stale.** Both runtimes already accept
a bare scalar for a single-field value object; the refusal exists only for multi-field types.
The claim that Rust refuses a bare scalar on purpose came from the outside review and does not
hold. The agent read code, generated output and specs; it did not run a bare-scalar call live
on either runtime, so the maintainer should confirm that once.

**Facts**
- Ruby: `Value::Coercion#for_attribute` (`lib/hecks/runtime/value/coercion.rb:112`) wraps a bare
  scalar into the sole field when the value object has exactly one attribute (`:387`). Anything
  else that is not an object raises `TypeMismatch` (`:389`, wording at `vocabulary.rb:300`).
- Rust: `Json::coerce_single_field` (`rust/src/kernel/json.rs:307`) wraps a non-object;
  `expect_value_object_shape` (`:333`) refuses multi-field with the same wording. Both
  generators emit the choice (`rust/project/json_codec.rb:115-128,251`,
  `rust/codegen/src/json_codec.rs:107-124,226`), for example
  `rust/src/generated/pizzas/order.rs:679`. The origin is commit `a144829f`.
- Documented: `docs/implemented/reference/value_object.md:66-75`,
  `guides/aggregates-and-value-objects.md:521-538`. Tested in Ruby by
  `spec/scalar_value_object_spec.rb:151-190`. No ADR says a bare scalar is refused.
- The `{ value: ... }` verbosity is docs and examples still using the explicit spelling:
  about 7 README lines, the pizzas behaviors file (26), banking (5), and about 250 lines across
  guides and reference. The UI schema keeps `{value: ...}` as a wire shape by choice
  (`rust/host/src/ui_schema.rs:11-21`).
- Residual fragility: the collapse is implicit and gated on attribute count, so adding a second
  field to a value object flips every existing bare call from accepted to `TypeMismatch`.
- No cross-runtime corpus fixture pins single-field bare-scalar acceptance; only the Ruby spec,
  the fuzzer and codegen parity cover it.

**Sketches (not implemented)**
1. A declaration on the value object (a flag replacing the `size == 1` test). Makes the intent
   explicit; needs an IR flag, both runtimes and regenerated code, and is breaking unless the
   default stays "single field means yes".
2. A per-attribute marker (`bare: true`), like `optional:` and `default:`. Cheapest hook; must
   be repeated at each use.
3. A boundary-only projection at each entry point. No IR or core change, but each entry point
   copies what the core already does and can drift.

**Recommendation from prep.** Do not pursue new syntax; close as already shipped. The small
residual: sweep the README and the pizzas and banking examples to the bare form, and add a
cross-runtime `spec/corpus/rust_conformance/` fixture pinning bare-scalar acceptance. If the
implicit rule ever hurts, react to sketch 2 first.

**For the maintainer**
1. Was "Rust refuses on purpose" a decision that is not visible in the repo, or a misreading of
   the multi-field refusal?
2. Is the implicit `attributes.size == 1` rule acceptable?
3. Should the README and examples show the bare form, or keep `{ value: }` for teaching?
4. Is a cross-runtime pin fixture wanted?

## Answer

Decided 2026-09-27: close as already shipped and add no new syntax. Follow-ups: confirm with one
live bare-scalar call on each runtime, sweep the README and the pizzas and banking examples to
the bare form (keeping `{ value: ... }` only where a document teaches that shape), and add a
cross-runtime fixture pinning single-field bare-scalar acceptance. Recorded in
[ADR 0067](../../../decisions/0067-a-single-attribute-value-object-takes-a-bare-scalar.md).
