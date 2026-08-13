# DomainPort

Words available inside `port do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## operation

<!-- generated:begin word=operation -->
`operation name do ... end` — opens a `PortOperation` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Opens one translation from an external fact into this domain's own event vocabulary — `reference_to`, `attribute`, and `emits`, nothing else: the builder behind it defines no `given` or `then_set`, so an operation cannot read aggregate state or mutate a record itself. A `port` declares `operation`s or a `verb` (below) — never both, and never neither. Pizzas' `PaymentGateway` port and its `Receive` operation (`examples/pizzas/bluebook/pizzas.hecksagon`) are the worked example — it only emits `PizzaPaymentReceived`; the actual rules (must have a topping, must still be available) stay on `Order`'s own `Purchase` command, reached through the `OnPizzaPaymentReceived` policy beside it. See the PortOperation reference page for the vocabulary inside.

## tells

<!-- generated:begin word=tells -->
`tells name do ... end` — opens a `PortOperation` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

What the outside TELLS this domain — an external fact arriving, translated
into the domain's own word for it. Identical to `operation`, which is the
spelling every chapter in this corpus still uses and which keeps working;
`tells` is the same word under a name that says which way it points, now
that it has a twin.

It emits, and that is all. There is no channel back to whoever called: an
inbound operation is the anti-corruption boundary, and whatever should
happen next happens wherever a `policy` reacts to the event it emitted.
Declaring `answers` or `refuses` on one is refused when the bluebook builds.

## asks

<!-- generated:begin word=asks -->
`asks name do ... end` — opens a `PortOperation` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

What this domain ASKS of the outside — the direction the language did not
have until it was added, and the reason a `port` can now be read in both
directions.

Before it, a domain could be *called by* an adapter and never call one:
`Ports::Extraction.adapter.canonical(...)` is library code reaching for an
adapter, and `MockStripeAdapter#create_session` is an application doing the
same. Neither is the domain asking, and neither leaves a trace in the record.

An `asks` is dispatched like any other port operation — a `policy` can
`trigger` it off an event, because the dispatcher resolves ports before
entities — and it comes back as one of the two events it named. That is what
makes the outside world something the model can reason about instead of a
place exceptions come from.

It must name both endings (`answers` and `refuses`) and may not `emits`.
An ask that named only its happy ending would put the failure somewhere the
model cannot see, which is the whole reason a boundary is worth modelling.

## verb

<!-- generated:begin word=verb -->
`verb verb` — fills `verb`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | verb |
<!-- generated:end -->

The driven half of the same `port` call — a swappable resource port
(`persisted_by`, `opened_by`, a project's own `provided_by`) rather than a
translation of an inbound fact. `verb "opened_by"` registers the exact same
`IR::Port` a standalone `.port` file's `Hecks.port "name" do verb "..."
end` would, reached by whichever adapters declare `port "Checkout"` and
bound the same way — one line, next to the aggregate it belongs to,
instead of a separate file. A port is a `verb` or one-or-more `operation`s,
never both; declaring neither, or both, refuses to build. See
writing-an-adapter.md's own section on resource ports for a worked
example.

