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

Opens one translation from an external fact into this domain's own event vocabulary — `reference_to`, `attribute`, and `emits`, nothing else: the builder behind it defines no `given` or `then_set`, so an operation cannot read aggregate state or mutate a record itself. A `port` with no `operation` inside it refuses to build. Pizzas' `PaymentGateway` port and its `Receive` operation (`examples/pizzas/bluebook/pizzas.hecksagon`) are the worked example — it only emits `PizzaPaymentReceived`; the actual rules (must have a topping, must still be available) stay on `Order`'s own `Purchase` command, reached through the `OnPizzaPaymentReceived` policy beside it. See the PortOperation reference page for the vocabulary inside.

