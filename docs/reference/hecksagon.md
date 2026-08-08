# Hecksagon

Words available inside `hecksagon do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## subscribe

<!-- generated:begin word=subscribe -->
`subscribe subscriptions` — fills `subscriptions`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | subscriptions |
<!-- generated:end -->

Names an event this hecksagon takes in from outside its own bluebook. It is declarative only, today — recorded on the registry (`runtime.registry.hecksagon(domain).subscriptions`) and readable back after boot, but nothing routes a subscribed event anywhere by itself. If a feature needs one to actually trigger a reaction, that reaction is still a `policy`, wired the ordinary way.

## uses_framework

<!-- generated:begin word=uses_framework -->
`uses_framework framework_members` — fills `framework_members`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | framework_members |
<!-- generated:end -->

Names a `framework/bluebook/` member this domain wants attached — `uses_framework "Governance"`, say. Attaching one is a deployment decision, the same kind `persisted_by`/`projected_by` already are, so it lives in the hecksagon rather than as a fact stated in the domain's own bluebook. Loads that member's own bluebook, then its own hecksagon, into whatever registry this one is loading into — always from `framework/bluebook/`'s own real location, never a copy, so it keeps working even when this domain is itself copied somewhere else first (a fuzz run's isolated tmp boot, for instance).

## port

<!-- generated:begin word=port -->
`port name do ... end` — opens a `DomainPort` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

A driving port: a second front door for a fact that didn't originate inside the domain (a payment webhook, a card terminal). Called bare, as documented here, it belongs to the chapter as a whole rather than one aggregate. The more common shape in practice is the aggregate-scoped sibling — `Pizzas::Order.port "PaymentGateway" do ... end`, the same receiver `persisted_by` already reaches (see `examples/pizzas/bluebook/pizzas.hecksagon`) — which attaches to one record's own box instead. Either way the body only admits `operation`; see the DomainPort reference page.

