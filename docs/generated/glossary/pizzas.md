# Pizzas — Glossary

> Put toppings on a pizza and sell it to a customer.

The ubiquitous language: every term Pizzas declares, grouped under the aggregate it belongs to, in the domain's own words. Generated from `Pizzas`'s bluebook — a term missing here is a term the bluebook does not yet declare, and a definition missing here is a sentence nobody has written yet.

## Order

| Term | Kind | Definition |
|---|---|---|
| **Order** | Aggregate | An order that gathers toppings on a pizza and is eventually sold to a customer. |
| **Order** | Lifecycle | Starts at `available`. States: `available`, `sold`. |
| **CustomerName** *(Order)* | Value Object | { value: String } Must satisfy: a customer is named. |
| **Pizza** *(Order)* | Value Object | { price_cents: Price, size: Size } |
| **PizzaName** *(Order)* | Value Object | { value: String } Must satisfy: a pizza is named. |
| **Price** *(Order)* | Value Object | { cents: Integer } Must satisfy: a price is never negative. |
| **Size** *(Order)* | Value Object | One of `small`, `large`. |
| **Topping** *(Order)* | Value Object | { name: String, amount: Integer } |
| **ToppingAmount** *(Order)* | Value Object | { value: Integer } Must satisfy: an amount is positive. |
| **ToppingName** *(Order)* | Value Object | { value: String } Must satisfy: a topping is named. |
| **AddTopping** *(Order)* | Command | Customize a pizza with an ingredient |
| **CreatePizza** *(Order)* | Command | Put a new pizza on the menu |
| **Purchase** *(Order)* | Command | Buy the pizza |
| **Available** *(Order)* | Query | — |
| **CostingLessThan** *(Order)* | Query | — |
| **Expensive** *(Order)* | Query | — |
| **PizzaCreated** | Event | Raised by `CreatePizza`. |
| **PizzaPurchased** | Event | Raised by `Purchase`. |
| **ToppingAdded** | Event | Raised by `AddTopping`. |

## Roles

| Term | Kind | Definition |
|---|---|---|
| **Chef** | Role | Issues `CreatePizza`, `AddTopping`. |
| **Customer** | Role | Issues `Purchase`. |

## Cross-Domain Reactions

| Term | Kind | Definition |
|---|---|---|
| **OnPizzaPaymentReceived** | Policy | On `PizzaPaymentReceived`, dispatches `Order.Purchase`. |
