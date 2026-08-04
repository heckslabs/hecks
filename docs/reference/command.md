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

Names who calls this command — "Orchardist", "Cidermaker". It travels with the command's `to_h` for anything downstream that wants to show it, but nothing in the runtime reads it back to authorize a caller; declaring `role "Cidermaker"` does not stop anyone else from calling `Press`.

## goal

<!-- generated:begin word=goal -->
`goal goal` — fills `goal`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | goal |
<!-- generated:end -->

A one-line statement of intent — "Bring in one basket and count it toward the tree's yield." Descriptive only, same as `role`: nothing enforces that the command's body actually does what its `goal` claims.

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
`sets target, to:, append:, increment:, decrement:` — fills `mutations`, was `then_set`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | target |
| `to:` | literal | false | source |
| `append:` | literal | false | source |
| `increment:` | literal | false | source |
| `decrement:` | literal | false | source |
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

Declares an argument this command needs, scalar or value object — same word, same modifiers, as an aggregate's own `attribute`. See the Type and ValueObject context pages for what each type position and modifier does.

## ensures

<!-- generated:begin word=ensures -->
`ensures do ... end` — fills `ensures`
<!-- generated:end -->

A postcondition, read AFTER the mutation runs but before `save` — `old` names the record as it stood before, so the check can assert a relationship between the two states, not just a fact about one. A false read raises `EnsuresNotMet` and the write never reaches the store. See commands.md for why this catches what a forgotten `given` doesn't.

