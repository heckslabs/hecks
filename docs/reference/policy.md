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
committed fact — the policy adds no condition of its own, unlike a
command's `given`.

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

