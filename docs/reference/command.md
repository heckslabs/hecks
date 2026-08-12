# Command

Words available inside `command do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## role

<!-- generated:begin word=role -->
`role role` — fills `role`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | role |
<!-- generated:end -->

Names who calls this command — "Compliance officer", "Back office". Optional: a command with no declared `role` is never checked against anything. Where it IS declared, enforcement is opt-in on the caller's side too — unchecked by default, real once a caller states one. `Hecksagain.as_caller(role:, &block)` binds who is dispatching for the block (`Runtime::Caller`, `Thread.current`-backed, safe under nesting); a command whose declared `role` doesn't match refuses with `Unauthorized` (`CommandRules::Authorization#refuse_role_mismatch`, the `role_mismatch` refusal template). A policy or saga reaction never inherits the triggering caller's role — `Dispatcher#reenter` clears it, since a reaction is the system acting, not the original caller.

## goal

<!-- generated:begin word=goal -->
`goal goal` — fills `goal`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | goal |
<!-- generated:end -->

A one-line statement of intent — "Bring in one basket and count it toward the tree's yield." Descriptive only, unlike `role`: nothing enforces that the command's body actually does what its `goal` claims.

## provenance

<!-- generated:begin word=provenance -->
`provenance from:` — fills `provenance`

| argument | kind | required | fills |
|---|---|---|---|
| `from:` | literal | true | provenance |
<!-- generated:end -->

The same fact `Aggregate#provenance` records, one level down — where a
command's own concept came from, when the command itself was adopted from a
canonical source rather than authored here. Same shape, same raw Hash, same
rule: nothing but a human, or future tooling, ever reads it.

## reference_to

<!-- generated:begin word=reference_to -->
`reference_to type, as:, optional:` — fills `references`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
| `optional:` | flag | false | optional |
<!-- generated:end -->

Whether this reference names the command's OWN aggregate decides everything: reference a different aggregate and the command creates, landing as a class method (`Tree.plant`); reference the aggregate it's declared on and the command acts on an existing record, landing as an instance method (`tree.harvest`). See commands.md's "Creating vs. acting" for the full split and the `AlreadyExists`/`NotFound` refusals each side produces.

## given

<!-- generated:begin word=given -->
`given description do ... end` — fills `givens`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

A precondition, read against the record BEFORE any mutation runs. The first one that reads false refuses the whole dispatch with `GivenNotMet`, message exactly the `description` text — the rest never run. See commands.md for why the cheapest or most-likely-to-fail `given` belongs first.

## sets

<!-- generated:begin word=sets -->
`sets target, to:, append:, increment:, decrement:, from:, multiply:, clamp:, remove:` — fills `mutations`, was `then_set`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | target |
| `to:` | literal | false | source |
| `append:` | literal | false | source |
| `increment:` | literal | false | source |
| `decrement:` | literal | false | source |
| `from:` | literal | false | source |
| `multiply:` | literal | false | source |
| `clamp:` | literal | false | source |
| `remove:` | literal | false | source |
<!-- generated:end -->

Still spelled `then_set` in every real bluebook in this codebase — `was: "then_set"` in the language's own rename table, and the old spelling keeps booting alongside the new one. One call, one op: `to:` overwrites the field, `append:` grows a list attribute by one value object built from the pairs you name, `increment:`/`decrement:` do arithmetic on a numeric field. See commands.md's "`then_set` — one op per field" for the flattening rule `append:` applies to a single-member value object.

## emits

<!-- generated:begin word=emits -->
`emits emits` — fills `emits`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | emits |
<!-- generated:end -->

Names an event announced once the record is actually saved — `save` runs before `emit`, so a command that refuses after mutating never announces anything. One command may declare `emits` more than once, when a single act is really two facts worth reacting to separately.

## attribute

<!-- generated:begin word=attribute -->
`attribute name, type, type, default:, optional:, pattern:, admits:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
| positional 2 | constant | false | type |
| positional 2 | text | false | type |
| `default:` | literal | false | default |
| `optional:` | flag | false | optional |
| `pattern:` | text | false | pattern |
| `admits:` | text | false | admits |
<!-- generated:end -->

Declares an argument this command needs, scalar or value object — same word, same modifiers, as an aggregate's own `attribute`. See the Type and ValueObject context pages for what each type position and modifier does.

## ensures

<!-- generated:begin word=ensures -->
`ensures description do ... end` — fills `ensures`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

A postcondition, read AFTER the mutation runs but before `save` — `old` names the record as it stood before, so the check can assert a relationship between the two states, not just a fact about one. A false read raises `EnsuresNotMet` and the write never reaches the store. See commands.md for why this catches what a forgotten `given` doesn't.

