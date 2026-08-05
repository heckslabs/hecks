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

