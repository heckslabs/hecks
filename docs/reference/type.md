# Type

Words available in the type position of an `attribute`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## list_of

<!-- generated:begin word=list_of -->
`list_of constant`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true |  |
<!-- generated:end -->

Wraps a type as a repeating field — `attribute :tags, list_of(Tag)` — a
list of `Tag` value objects, each built (and checked) the same way a
single `Tag` would be.

## one_of

<!-- generated:begin word=one_of -->
`one_of literal`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | literal | true |  |
<!-- generated:end -->

The inline closed-set shorthand — `attribute :finish, one_of("matte",
"glossy")` — synthesises a fresh value object for just this attribute.
It CANNOT be used inside a `value_object` block: it desugars by calling
`one_of` on the enclosing builder, and a nested `value_object` already
defines its own DIFFERENT `one_of` (the block form, see one_of.md) —
wrong arity, and the bluebook fails to load. Give the set its own
sibling `value_object` instead when it needs to live inside another
value object. Full story in aggregates-and-value-objects.md.

