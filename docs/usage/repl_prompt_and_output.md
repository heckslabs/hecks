# REPL Prompt and Output

The Hecks workshop REPL shows contextual feedback in two ways:

1. **Last event in prompt** -- after executing a command, the prompt shows which event fired
2. **Real return values** -- commands return the aggregate with a readable inspect

## Last Event in Prompt

After any command execution in play mode, the REPL prompt updates to show the
most recent domain event:

```
hecks(pizzas sketch)> play!
hecks(pizzas play)> Pizza.create(name: "Margherita", style: "NY")
=> #<Pizza id:abc12345 name: "Margherita" style: "NY">

hecks(pizzas play) [CreatedPizza]> Pizza.rename(name: "Classic Margherita")
=> #<Pizza id:abc12345 name: "Classic Margherita" style: "NY">

hecks(pizzas play) [RenamedPizza]>
```

The prompt format is: `hecks(<domain> <mode>) [<last event>]`

## Inspecting the Last Event

Call `last_event` to get the full event object:

```ruby
hecks(pizzas play) [CreatedPizza]> last_event
=> #<CreatedPizza occurred_at: 2026-04-01 ...>
```

Returns `nil` when not in play mode or when no events have been emitted.

## Real Return Values

Commands return the actual aggregate instance with a concise `inspect`:

```ruby
pizza = Pizza.create(name: "Margherita", style: "NY")
# => #<Pizza id:a1b2c3d4 name: "Margherita" style: "NY">

pizza.name
# => "Margherita"

Pizza.find(pizza.id)
# => #<Pizza id:a1b2c3d4 name: "Margherita" style: "NY">

Pizza.all
# => [#<Pizza id:a1b2c3d4 name: "Margherita" style: "NY">]
```

The inspect format shows: `#<ClassName id:<first 8 chars> attr1: val1 attr2: val2>`
