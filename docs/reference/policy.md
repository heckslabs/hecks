# Policy

Words available inside `policy do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## on

<!-- generated:begin word=on -->
`on on_event` — fills `on_event`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | on_event |
<!-- generated:end -->

The event this policy reacts to. By the time it arrives it is already a
committed fact — `on` names it unconditionally; `where`, below, is
where a policy adds a condition of its own.

## trigger

<!-- generated:begin word=trigger -->
`trigger trigger_command` — fills `trigger_command`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | trigger_command |
<!-- generated:end -->

The command `on`'s event fires, named bare — `"Aggregate.Command"`,
never domain-prefixed — because it defaults to this policy's own
domain; see `across` to reach another one. The event's whole payload
forwards verbatim as the command's arguments, so the two shapes have to
agree before either is written. A policy that ends up triggering the
event it reacts to does not loop forever: `Dispatcher::MAX_REACTION_DEPTH`
(5) stops the chain and records why.

## across

<!-- generated:begin word=across -->
`across target_domain` — fills `target_domain`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | target_domain |
<!-- generated:end -->

Names the domain a `trigger` reaches into when it lives outside this
policy's own. Leave it off and `trigger` is assumed to name a command
in the same domain as the event that fired it — the ordinary case.

## where

<!-- generated:begin word=where -->
`where do ... end` — fills `where`
<!-- generated:end -->

A guard on whether this policy fires at all, read against the
triggering event's own payload — `where { amount.cents > 1_000_00 }`.
Same extraction as a command's `given`/`ensures` (the block's source is
read once, at build time, and never called directly — only the
extracted text is evaluated, by the same expression evaluator a
command's own rules run through), but no description argument the way
`given`/`ensures` each carry one: a `given`'s description becomes a
refusal message, and a `where` that does not hold refuses nothing — the
policy is silently a no-op for that event, exactly like an event
qualifier (`on "Account.Frozen"` vs. a `Payment.Frozen`) that does not
match. Nothing is logged either way; a policy that never applies to an
event leaves no more trace than one that was never declared.

## for_each

<!-- generated:begin word=for_each -->
`for_each for_each` — fills `for_each`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | for_each |
<!-- generated:end -->

Fan-out: `trigger` fires once per row a declared query answers, instead
of once for the event — `for_each "Account.OpenForCustomer"`. The named
query runs against the SAME domain the event belongs to, using the
event's own payload as the query's arguments, unless the verb is
itself domain-qualified (`"Domain::Aggregate.query_name"`) — the same
default a saga's own `dispatch` command name already takes. Each
matching row's own id is merged into the forwarded payload under the
iterated aggregate's own reference-key convention (`account_id` for
`Account` — the same name a bare `reference_to Account` would mint), so
`trigger`'s target command addresses the right record without either
side having to say the argument's name twice. `where`, above, still
gates the whole fan-out, evaluated once against the event, not once
per row.

