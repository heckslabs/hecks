# Pizzas — Glossary

> Put toppings on a pizza and sell it to a customer.

The ubiquitous language: every term Pizzas declares, alphabetized, in the domain's own words. Generated from `Pizzas`'s bluebook — a term missing here is a term the bluebook does not yet declare, and a definition missing here is a sentence nobody has written yet.

| Term | Kind | Definition |
|---|---|---|
| **AddTopping** *(Order)* | Command | Customize a pizza with an ingredient |
| **Available** *(Order)* | Query | — |
| **Chef** | Role | Issues `CreatePizza`, `AddTopping`. |
| **CostingLessThan** *(Order)* | Query | — |
| **CreatePizza** *(Order)* | Command | Put a new pizza on the menu |
| **Customer** | Role | Issues `Purchase`. |
| **CustomerName** *(Order)* | Value Object | { value: String } Must satisfy: a customer is named. |
| **Expensive** *(Order)* | Query | — |
| **OnPizzaPaymentReceived** | Policy | On `PizzaPaymentReceived`, dispatches `Order.Purchase`. |
| **Order** | Aggregate | An order that gathers toppings on a pizza and is eventually sold to a customer. |
| **Order** | Lifecycle | Starts at `available`. States: `available`, `sold`. |
| **Pizza** *(Order)* | Value Object | { price_cents: Price, size: Size } |
| **PizzaCreated** | Event | Raised by `CreatePizza`. |
| **PizzaName** *(Order)* | Value Object | { value: String } Must satisfy: a pizza is named. |
| **PizzaPurchased** | Event | Raised by `Purchase`. |
| **Pizzas** | Domain | Put toppings on a pizza and sell it to a customer. |
| **Price** *(Order)* | Value Object | { cents: Integer } Must satisfy: a price is never negative. |
| **Purchase** *(Order)* | Command | Buy the pizza |
| **Size** *(Order)* | Value Object | One of `small`, `large`. |
| **Topping** *(Order)* | Value Object | { name: String, amount: Integer } |
| **ToppingAdded** | Event | Raised by `AddTopping`. |
| **ToppingAmount** *(Order)* | Value Object | { value: Integer } Must satisfy: an amount is positive. |
| **ToppingName** *(Order)* | Value Object | { value: String } Must satisfy: a topping is named. |
