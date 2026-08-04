# ValueObject

Words available inside `value_object do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## attribute

<!-- generated:begin word=attribute -->
`attribute name, type, default:, optional:, pattern:, admits:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
| positional 2 | constant | false | type |
| `default:` | literal | false | default |
| `optional:` | flag | false | optional |
| `pattern:` | text | false | pattern |
| `admits:` | text | false | admits |
<!-- generated:end -->

Declares a field on the value object: a name, a type (scalar or another
value object), and the usual `default:`/`optional:`/`pattern:`/`admits:`
modifiers — same word, same rules, as inside an aggregate. See
aggregates-and-value-objects.md for what each modifier promises.

## one_of

<!-- generated:begin word=one_of -->
`one_of do ... end` — fills `rows`
<!-- generated:end -->

Opens the closed-set block form: a value object whose only legal values
are the `member`s declared inside. This is a DIFFERENT `one_of` from the
inline type-position shorthand documented on type.md — calling that
shorthand from inside a nested `value_object` block reaches THIS `one_of`
instead, with the wrong arity, and crashes. See type.md's `one_of`
section and aggregates-and-value-objects.md for the full trap.

## invariant

<!-- generated:begin word=invariant -->
`invariant description do ... end` — fills `invariants`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

A rule that travels with the value, not with any one command — it fires
in every command that carries this value object, not just the one where
it was declared. See command.md for where an invariant sits relative to
a command's other checks.

