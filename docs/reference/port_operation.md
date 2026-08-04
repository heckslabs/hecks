# PortOperation

Words available inside `operation do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## reference_to

<!-- generated:begin word=reference_to -->
`reference_to type, as:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
<!-- generated:end -->

The record this operation's external fact is about; `as:` picks the
argument name, so the port's payload can key-match the command a
policy will later forward it to.

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

An extra field the external fact carries, declared the same way a
command's own `attribute` is.

## emits

<!-- generated:begin word=emits -->
`emits emits` — fills `emits`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | emits |
<!-- generated:end -->

The event this operation announces once called. `reference_to`,
`attribute`, and `emits` are the whole of what a driving port's
operation may declare — no `given`, no `then_set`; it translates an
external fact into the domain's own event vocabulary and stops there
(see wiring.md).

