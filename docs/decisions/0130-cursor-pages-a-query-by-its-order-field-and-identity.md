# `cursor` pages a query by its order field and identity

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-24.

## Context

The Paging chapter accepts `cursor`, and `QueryBuilder#seal_cursor` refuses it at build:
"no interpreter implements cursor pagination". `limit` and `offset` are numbers written in
the bluebook, so a caller cannot ask for page 3. A Rails read side, and `BulkRun` (which
walks a query's rows and fell back to reading them all), both need to page a query by a
position the caller holds.

## Decision

1. **`cursor :field` keys a query's position on its order field.** The field must be the
   query's `order_by` field, or `:id` when the query declares no `order_by`. The query must
   also declare a `limit`, which is then the page size, and must not declare `offset`. Each
   refusal names the fix. A query on an entity, and a read model, still refuse `cursor`
   (read models keep their own, sharper refusal until their many-side head pages).
2. **The sequence is `(field, identity)`.** Identity is the tiebreak in the same direction
   as the field, exactly the order `Ports::Query::Ordering` and `NullPolicy.sql_order`
   already give. `nulls` places nulls and the cursor respects it: a null-keyed row has a
   position like any other. A page boundary therefore never repeats or drops a row, ties
   included.
3. **An implicit optional argument `after`.** It is an opaque string, not a declared
   attribute. Absent, the query answers its first page. Present, it answers the rows that
   follow the position it names. A string a query did not hand out is refused.
4. **The position token is one pure function.** `Ports::Query::Cursor.encode(value, id)`
   is the URL-safe base64 of the JSON array `[value, id]`, where `value` is the row's
   comparable order value (`null` for a null-keyed row). The Rust kernel mirrors it. A
   token minted by one engine is read by the other.
5. **Every engine implements "follows `(value, id)`".** Memory, Heki, local storage and the
   interpreter filter the ordered rows with `Cursor.follows?`. The SQL dialects compile one
   keyset predicate into the `WHERE` (`SqlKeyset`), shared by SQLite, Postgres and
   PostgresEra, using the same expression as `ORDER BY` and placing nulls the way the
   `NULLS FIRST/LAST` clause does. The Rust kernel's `query_ordering` does the same.
6. **`Dispatcher#query_page(verb, after:, **args)` answers a page.** It returns
   `{rows:, after:}`: the query is run asking for `limit + 1` rows, the extra row proves
   there is a next page, and `after` is the token of the last row kept, or `nil` when
   nothing more remained. A page after the last row is empty with no `after`. `query`
   keeps returning `Array<Hash>` (the first `limit` rows after `after`), so every current
   caller is untouched. The Rust kernel gains `named_query::run_page` with the same answer.

## Consequences

- No new word: `cursor` stops refusing. The generated Rust now compiles a cursor query
  (`QueryDef.cursor`) instead of skipping it.
- Paging goes forward only. There is no total count: a count is a scan.
- A query answered from outside the domain (a hecksagon-bound port) ignores `after`; the
  adapter owns its own paging.
- Fuzzing gains `cursor_walk_yields_the_unpaged_query`: walking pages by cursor yields
  exactly the rows of the unpaged query, in order, none twice, on every adapter. The
  conformance corpus carries one case, and `examples/banking` declares a cursor query.
