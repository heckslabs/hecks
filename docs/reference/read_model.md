# ReadModel

Words available inside `read_model do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## description

<!-- generated:begin word=description -->
`description description` — fills `description`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

A free-text label for the read model — no rules attached, read by
nothing but a human.

## reference_to

<!-- generated:begin word=reference_to -->
`reference_to reference_target, as:` — fills `reference_target`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | reference_target |
| `as:` | symbol | false | reference_name |
<!-- generated:end -->

Names the aggregate this read model is anchored to — the one record
every row centers on, everything else in `include` comes back a
collection around it (see `include`). A read model declares only one;
a second `reference_to` is refused when the bluebook builds.

## include

<!-- generated:begin word=include -->
`include aggregate, as:` — fills `aggregate_heads`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | aggregate |
| `as:` | symbol | false | as |
<!-- generated:end -->

Gathers another aggregate into the read model alongside the reference.
Cardinality is inferred, not declared: the reference target comes back
as the one record, any other included aggregate comes back as a list
— there's no `many:` to spell out yourself. Declaring the same `as:`
name twice is refused. See the queries-and-read-models guide for the
full `Roster` example.

## where

<!-- generated:begin word=where -->
`where pairs` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | pairs | true |  |
<!-- generated:end -->

Same eight comparators as a query's `where` (`eq`, `ne`, `gt`, `gte`,
`lt`, `lte`, `in`, `contains`). Worth knowing before you rely on it:
the build-time seal that catches an undeclared field, a non-numeric
ordered comparison, or an unresolved `:symbol` argument on an
aggregate's own `query` walks each aggregate's declared queries, and a
read model isn't one — that seal doesn't run here. Worse, neither
runtime path that answers a read model (`ReadModelInterpreter`, or
`SqliteProjection#query_read_model` where an adapter defines one) reads
`wheres` off the declared model at all; declaring `where` on a
`read_model` today changes nothing about what comes back.

## order_by

<!-- generated:begin word=order_by -->
`order_by field, direction` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | field |
| positional 2 | symbol | false | direction |
<!-- generated:end -->

Same shape as a query's `order_by`, but not applied: neither runtime
path that answers a read model reads it. Rows on the "many" side of an
`include` come back sorted by record id regardless of what this names
— both `ReadModelInterpreter` and `SqliteProjection` sort that way
unconditionally, not because `order_by` asked for it.

## limit

<!-- generated:begin word=limit -->
`limit value` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | number | true | value |
<!-- generated:end -->

Same shape as a query's `limit`, but not applied by either runtime
path that answers a read model — declaring it doesn't trim a read
model's rows.

## offset

<!-- generated:begin word=offset -->
`offset value` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | number | true | value |
<!-- generated:end -->

Same shape as a query's `offset`, and equally unapplied here — see
`cursor` for the one behavior this pair still triggers on the `query`
side that a read model doesn't get.

## cursor

<!-- generated:begin word=cursor -->
`cursor value` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | value |
<!-- generated:end -->

Declares an opaque pagination cursor. On the aggregate-`query` path
this pairs with `offset` to trigger a build-time refusal
(`Ports::Query.validate!`); a read model never reaches that check at
all — the read model runtime doesn't call `Ports::Query`, so today
neither that refusal nor any actual pagination happens here.

## consistency

<!-- generated:begin word=consistency -->
`consistency mode, timeout:` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | mode |
| `timeout:` | number | false | timeout |
<!-- generated:end -->

Declares a consistency mode and an optional `timeout:`. Captured on
the specification and serialized for an adapter to see; nothing in
this codebase's adapters or the read model runtime reads it back yet
— metadata, not an enforced guarantee.

## freshness

<!-- generated:begin word=freshness -->
`freshness mode, max_age:` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | mode |
| `max_age:` | number | false | max_age |
<!-- generated:end -->

Declares a freshness mode and an optional `max_age:`. Same status as
`consistency` — recorded on the specification, read by nothing here.

## authorize

<!-- generated:begin word=authorize -->
`authorize policy, tenant:` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | policy |
| `tenant:` | symbol | false | tenant |
<!-- generated:end -->

Declares a policy and an optional `tenant:` the ask should be checked
against. Recorded on the specification only; nothing here evaluates
it.

## nulls

<!-- generated:begin word=nulls -->
`nulls mode` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | mode |
<!-- generated:end -->

Sets how nulls sort relative to real values. On the aggregate-`query`
path both the in-memory and SQL ordering read this; the read model
runtime never reads `null_semantics` at all, so it's currently just
accepted syntax here — a read model doesn't apply a declared order in
the first place (see `order_by`).

## inspect_query

<!-- generated:begin word=inspect_query -->
`inspect_query mode` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | false | mode |
<!-- generated:end -->

Asks to inspect the compiled query. On the aggregate-`query` path this
is a capability gate through `Ports::Query.validate!`; the read model
runtime never reaches that code at all, so declaring it here has no
effect, refusal or otherwise.

## use_index

<!-- generated:begin word=use_index -->
`use_index name` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
<!-- generated:end -->

Names an index hint. Recorded on the specification and round-trips
through the IR; no adapter here reads it back for a read model any
more than it does for a query.

