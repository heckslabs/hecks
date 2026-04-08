# Pizzas Example

A complete Hecks domain with Pizza and Order aggregates, value objects, commands, events, validations, and policies. Three runnable scripts show different ways to use the framework.

## Domain

`domain.rb` defines two aggregates:

- **Pizza** — name, description, toppings (list of Topping value objects), with a presence validation on name. Commands: `CreatePizza`, `AddTopping`. Query: `ByDescription`.
- **Order** — references Pizza by ID, has quantity and status. Commands: `PlaceOrder`, `CancelOrder`, `ReserveStock`. Query: `Pending`. Policy: `ReserveIngredients` fires when an order is placed.

## Running the Examples

All scripts run from the hecks project root:

### pizzas.rb — Application Container

The full workflow: load domain, build gem (CalVer auto-stamped), wire the Application container with memory adapters, use the ActiveRecord-style API, and collection proxies.

```
ruby -Ilib examples/pizzas/pizzas.rb
```

What it demonstrates:
- `Hecks.build` to generate the domain gem
- `Hecks::Services::Application.new(domain)` to wire everything up
- `Pizza.create(name: ...)` to dispatch commands via short method names
- `pizza.toppings.create(name: "Mozzarella", amount: 2)` collection proxies
- `Pizza.find(id)` / `Pizza.all` / `Pizza.count` repository methods
- `Pizza.by_description("Classic")` DSL query objects
- `app.on("CreatedPizza") { ... }` to subscribe to events
- Value object creation and freezing

### repl_session.rb — Interactive Domain Building

Builds the domain incrementally using the REPL session API, demonstrates CalVer versioning, then switches to play mode to execute commands.

```
ruby -Ilib examples/pizzas/repl_session.rb
```

What it demonstrates:
- `Hecks.session("Pizzas")` to start a session
- `session.aggregate("Pizza")` returns a handle
- `pizza.attr`, `pizza.command`, `pizza.value_object` for incremental building
- `pizza.describe` and `session.describe` to review
- `session.validate` to check DDD rules
- `pizza.preview` to see generated code
- `session.save` to write domain.rb
- `session.build` to generate the domain gem
- `session.play!` to switch to play mode
- `session.execute("CreatePizza", ...)` to fire commands and see events
- `session.to_dsl` to export back to DSL source

### sql_app.rb — SQL Adapter Generation

Generates SQL schema and adapter classes, then runs a live SQLite demo with real persistence using the short API style.

```
ruby -Ilib examples/pizzas/sql_app.rb
```

Requires `gem install sqlite3` for the live demo. Without SQLite installed, it still shows the generated schema and adapter source code.

What it demonstrates:
- `SqlMigrationGenerator` producing CREATE TABLE statements with join tables for value objects
- `SqlAdapterGenerator` producing Sequel-based repository classes
- Value object hydration from join tables (Pizza with Toppings round-trips through SQL)
- Sequel handles SQLite, MySQL, and Postgres — same generated code works everywhere
- Adapter swapping: `Application.new(domain) { adapter "Pizza", sql_repo }`
- Short API: `Pizza.create(...)`, `Pizza.find(id)`, `Pizza.all`

## Generated Output

Running any of the scripts generates a `pizzas_domain/` directory (gitignored) containing the complete domain gem with source, specs, ports, and memory adapters. The version is auto-stamped using CalVer (e.g. `2026.03.20.1`).
