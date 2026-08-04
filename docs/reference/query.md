# Query

Words available inside `query do ... end`.

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

A free-text label for the query — no rules attached, read by nothing but a human.

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

Declares an argument this query accepts at ask-time, not a field on the
aggregate — the `:symbol` a `where` value can resolve from
(`attribute :ceiling, Draft` backs `where(draft: { lt: :ceiling })`). A
`:symbol` naming no such attribute is refused when the bluebook builds.

## where

<!-- generated:begin word=where -->
`where wheres` — fills `wheres`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | pairs | true | wheres |
<!-- generated:end -->

Filters on `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, and `contains` — a
bare value is shorthand for `eq`. The seal requires the field to be a
declared attribute or the lifecycle field, reached through any depth of
dotted path as long as it lands on a scalar (landing on a value object
is refused, and so is a field the aggregate never declared at all); the
ordered comparators additionally require that scalar to hold a number.
`contains` means real element membership on a `list_of` field and plain
substring on anything else — identically on every engine, including a
field whose own text carries a comma. See the queries-and-read-models
guide for the exact refusal wording.

## order_by

<!-- generated:begin word=order_by -->
`order_by order_field, order_way` — fills `order_field`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | order_field |
| positional 2 | symbol | false | order_way |
<!-- generated:end -->

Names the field to sort by, ascending unless the second argument is
`:desc`. The runtime always breaks ties by record identity underneath
whatever you declare, so an ask never silently falls back to store
order.

## limit

<!-- generated:begin word=limit -->
`limit limit` — fills `limit`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | number | true | limit |
<!-- generated:end -->

Caps how many rows survive after ordering runs. Declare `order_by`
first if you mean to keep a particular slice — limit trims what
ordering already sorted, it doesn't decide which rows those are.

## offset

<!-- generated:begin word=offset -->
`offset value` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | number | true | value |
<!-- generated:end -->

Skips that many rows after ordering, for paging. Refused together with
`cursor` on the same query — see `cursor`.

## cursor

<!-- generated:begin word=cursor -->
`cursor value` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | value |
<!-- generated:end -->

Refused at build (`QueryBuilder#seal_cursor`, raises `Malformed`). No
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

Declares a consistency mode and an optional `timeout:`. It's captured
on the specification and serialized for an adapter to see, but nothing
in this codebase's adapters or reference interpreter reads it back —
metadata you're handing downstream, not a guarantee this runtime
enforces yet.

## freshness

<!-- generated:begin word=freshness -->
`freshness mode, max_age:` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | mode |
| `max_age:` | number | false | max_age |
<!-- generated:end -->

Declares a freshness mode and an optional `max_age:`. Same status as
`consistency`: recorded on the specification, read by no adapter or
interpreter here — declarative, not enforced.

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
(`Runtime::TenantScope`), and every returned row — on every engine,
Memory, Sqlite, Postgres, and the entity/sub-list path alike — is
scoped to the value given, regardless of what other filters were
declared.

## nulls

<!-- generated:begin word=nulls -->
`nulls mode` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | mode |
<!-- generated:end -->

Sets how nulls sort relative to real values. This one is genuinely
enforced: both the in-memory ordering path and compiled SQL read it to
place nulls consistently rather than leaving it to whatever the store
happens to do.

## inspect_query

<!-- generated:begin word=inspect_query -->
`inspect_query mode` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | false | mode |
<!-- generated:end -->

Asks to inspect the compiled query rather than (or alongside) its
rows. In practice this is a capability gate more than a feature —
`Ports::Query.validate!` only refuses when an adapter neither
implements its own `inspect_query` hook nor exposes a native `query`
method under the default `:sql` mode. No adapter in this codebase
defines the former, so today declaring it never changes what comes
back; it can only ever refuse.

## use_index

<!-- generated:begin word=use_index -->
`use_index name` — fills `options`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
<!-- generated:end -->

Names an index hint. It's recorded on the specification and
round-trips through the IR, but no adapter here reads it back to
influence the query plan — the store still picks its own index.

