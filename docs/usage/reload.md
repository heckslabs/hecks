# reload! — Hot-reload the domain in play mode

Re-reads the current domain DSL definitions and reboots the playground
runtime without leaving play mode. Events and repository data are cleared
on reload.

## When to use

You've entered play mode, tested some commands, then realized you need to
add an attribute or tweak a command. Instead of `sketch!` / edit / `play!`,
just make the change and call `reload!`.

## REPL example

```ruby
# Start a workshop and enter play mode
workshop = Hecks.workshop("Pizzas")
pizza = workshop.aggregate("Pizza")
pizza.attr :name, String
pizza.command("CreatePizza") { attribute :name, String }
workshop.play!

# Execute a command
PizzasDomain::Pizza.create(name: "Margherita")
workshop.events  # => [#<CreatedPizza ...>]

# Add a new attribute while still in play mode
pizza.attr :size, String

# Reload picks up the change — events are cleared
workshop.reload!

# The new attribute is now available
PizzasDomain::Pizza.new(name: "Margherita", size: "Large")
```

## Web console

Type `reload!` in the web console input. In sketch mode it reloads the
domain files from disk; in play mode it recompiles and reboots the runtime.

## Notes

- Requires play mode — raises `RuntimeError` if called in sketch mode.
- Validates the domain before reloading. If invalid, prints errors and
  keeps the previous playground running.
- All captured events and in-memory repository data are cleared on reload.
