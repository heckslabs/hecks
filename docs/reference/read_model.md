# ReadModel

Words available inside `report do ... end`.

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

Optional: a read model with no `reference_to` at all is ROOTLESS — no
id argument at dispatch, every `include`d head reads its own aggregate
whole rather than being matched against a root. At least one `include`
is still required (a read model naming neither refuses). See
`group_by`, which this exists for.

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
full `ComplianceDashboard` example.

## group_by

<!-- generated:begin word=group_by -->
`group_by group_by` — fills `group_by`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | group_by |
<!-- generated:end -->

Nests the eligible collection's own rows into a Hash keyed by one or
more of its own field values, in the order named — `group_by :agg,
:state` on a `StateStyle` head comes back `{"Board" => {"open" =>
{...}, "archived" => {...}}}`, not a flat array. Held to the same
"exactly one many-side head" rule `where`/`order_by`/etc already are
(`ReadModelBuilder#seal_group_by`) — grouping is a question about ONE
collection's own rows. Requesting it also unwraps every single-
attribute value object on that head's own rows to its bare scalar
(`Runtime::Value.materialize_unwrapped`, not the plain `materialize`
every other head still gets) — grouping needs a real scalar to key by
regardless, so a read model already asking for that gets the unwrap
for free. Refuses at DISPATCH time (not build time — the aggregate
this read model targets isn't known until then) if a named field isn't
one the eligible collection's own aggregate actually declares.

This is also what makes `reference_to` optional: a read model with no
root — every `include`d head reading its own aggregate whole, no id
argument at dispatch — is `group_by`'s own real use (nesting a whole
table by its own field values has no root record to hang off).

## count

<!-- generated:begin word=count -->
`count` — fills `count`
<!-- generated:end -->

Reduces the eligible collection's own (already `where`-filtered)
rows to a single Integer — how many match, not which ones. A bare
word, no argument: its presence in the read model IS the value. Held
to the same "exactly one many-side head" rule `group_by`/`where`/etc
already are (`ReadModelBuilder#seal_aggregation`), and refused
together with `group_by` or with `median` — a read model reports one
shape. See `Banking::DisputedPaymentCount` for the real corpus
example.

## median

<!-- generated:begin word=median -->
`median median_field` — fills `median_field`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | median_field |
<!-- generated:end -->

Reduces the eligible collection's own (already `where`-filtered) rows
to the median of one numeric field — a bare number, or a value object
carrying one (the same "numeric" `where`/`order_by` already lean on).
An ODD number of rows answers the one true middle value ; an EVEN
number answers the AVERAGE of the two middle values, sorted (not the
lower or the upper of the two). An empty collection answers `nil`, not
zero — "nothing to average" is a different fact from "the values
averaged to zero." Refused at DISPATCH time if the named field doesn't
exist, or exists but isn't numeric — same timing as `group_by`'s own
field check, for the same reason (the aggregate this read model
targets isn't known until then). Same `seal_aggregation` rule `count`
carries: exactly one many-side head, never combined with `group_by` or
with `count`. See `Banking::DisputedPaymentMedian` for the real corpus
example.

## where

<!-- generated:begin word=where -->
`where pairs` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | pairs | true |  |
<!-- generated:end -->

Same eight comparators as a query's `where` (`eq`, `ne`, `gt`, `gte`,
`lt`, `lte`, `in`, `contains`), including the same real-membership-vs-
substring split on `contains` (see query.md's `where`). Applied for
real (`ReadModelInterpreter#project` and `SqliteProjection#query_read_model`
both run `Ports::Query::InMemory.execute` against it) — but only
against ONE collection: `ReadModelBuilder#seal_query_options` refuses
at build unless the read model includes exactly one many-side
aggregate, since `where`/`order_by`/`limit`/`offset`/`authorize`'s
tenant all have to mean the same collection or naming which one is
ambiguous. The "one" side (the reference target itself) is never
filtered — a single row has nothing to filter.

## order_by

<!-- generated:begin word=order_by -->
`order_by field, direction` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | field |
| positional 2 | symbol | false | direction |
<!-- generated:end -->

Same shape as a query's `order_by`, applied to the same one many-side
collection `where` is (see `where`). Without it, that collection still
comes back in a stable order (record id) — not because ordering is
optional, but because the underlying fetch has to answer in SOME
order, and id is the fallback every engine agrees on.

## limit

<!-- generated:begin word=limit -->
`limit value` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | number | true | value |
<!-- generated:end -->

Same shape as a query's `limit`, applied to the same one many-side
collection `where` is (see `where`).

## offset

<!-- generated:begin word=offset -->
`offset value` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | number | true | value |
<!-- generated:end -->

Same shape as a query's `offset`, applied to the same one many-side
collection `where` is (see `where`).

## cursor

<!-- generated:begin word=cursor -->
`cursor value` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | value |
<!-- generated:end -->

Refused at build (`ReadModelBuilder#seal_cursor`, raises `Malformed`). No
interpreter implements cursor pagination — declaring `cursor` here is
always an error, not a silent no-op. Use `limit`/`offset` instead.

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

Declares a policy name (recorded, never checked — no caller-identity or
grant system exists to check it against) and, when `tenant:` is given,
a mandatory tenant boundary that IS enforced: a caller must pass that
field as an argument or the ask refuses with `Unauthorized`
(`Runtime::TenantScope`), and every returned row is scoped to the
value given, regardless of what other filters were declared. `tenant:`
must name the same collection `where`/`order_by`/`limit`/`offset`
would (`ReadModelBuilder#seal_query_options` holds it to the same
"exactly one many-side head" rule).

## nulls

<!-- generated:begin word=nulls -->
`nulls mode` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | mode |
<!-- generated:end -->

Sets how nulls sort relative to real values, for the same one
many-side collection `order_by` sorts (see `order_by`). Same reading
on every engine as a `query`'s `nulls`.

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

