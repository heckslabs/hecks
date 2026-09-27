---
type: prototype
status: open
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

## Answer
