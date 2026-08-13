# PortOperation

Words available inside `operation do ... end` / `tells do ... end` / `asks do ... end`.

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

## answers

<!-- generated:begin word=answers -->
`answers answers` — fills `answers`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | answers |
<!-- generated:end -->

The event an `asks` becomes when the adapter came back — carrying whatever
it returned under `answered`, alongside the arguments the ask was made with.

Singular, where `emits` is a list: an ask has exactly one success. A call
that could succeed two different ways is two calls.

Refused on a `tells`, which has no channel back to its caller.

## refuses

<!-- generated:begin word=refuses -->
`refuses refuses` — fills `refuses`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | refuses |
<!-- generated:end -->

The event an `asks` becomes when the outside said no — carrying what it said
under `refusal`.

EVERY failure lands here, deliberately: a timeout, a bad credential, a
missing adapter, a nil where a number was wanted. A raise from the far side
of a boundary is not an exception in this domain's terms, it is the outside
refusing, and the chapter has already named the word for that. So an ask
never propagates — the command that triggered it stands, and a `policy`
reacting to this event is where a retry or a give-up lives (see banking's
`ScheduledPayment`, whose `attempts` counter and `Retry` command are the
worked example of exactly that shape).

Required on every `asks`. An ask that cannot fail is a call into a system
you do not control, pretending otherwise.

