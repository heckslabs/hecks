# Workshop Guide

The Workshop is an interactive domain-building environment with two modes: **sketch** for defining aggregates and commands, and **play** for executing commands against a live compiled runtime.

## Usage

```ruby
# Launch the console
$ hecks console Pizzas

# Sketch mode — define your domain
aggregate Pizza
Pizza.name String
Pizza.description String
Pizza.create

# Enter play mode — compiles and boots a live runtime
play!

# Execute commands
Pizza.create(name: "Margherita")
Pizza.create(name: "Hawaiian")

# Query persisted aggregates
Pizza.all.map(&:name)     # => ["Margherita", "Hawaiian"]
Pizza.find(id)            # => #<Pizza name="Margherita">
Pizza.count               # => 2

# Inspect events
events                    # => [#<CreatedPizza ...>, #<CreatedPizza ...>]
history                   # numbered timeline
commands                  # => ["CreatePizza(name: String) -> CreatedPizza"]

# Reset and start over
reset!

# Return to sketch mode
sketch!
```

## Sketch mode commands

| Command | Description |
|---|---|
| `aggregate Pizza` | Create or retrieve an aggregate |
| `Pizza.name String` | Add an attribute |
| `Pizza.create` | Add a command |
| `Pizza.create.name String` | Add an attribute to a command |
| `Pizza.lifecycle :status` | Add a lifecycle with a status field |
| `Pizza.transition "Publish" => "published"` | Add a status transition |
| `validate` | Check domain validity |
| `describe` | Print domain summary |
| `browse` | Interactive domain browser |
| `remove "Pizza"` | Delete an aggregate |
| `promote "Pizza"` | Extract aggregate into its own domain file |
| `build` | Compile the domain into a gem |
| `save` | Save the domain to a DSL file |

## Play mode commands

| Command | Description |
|---|---|
| `Pizza.create(name: "Margherita")` | Execute a command |
| `Pizza.all` | List all persisted aggregates |
| `Pizza.find(id)` | Find by id |
| `Pizza.count` | Count aggregates |
| `events` | All captured events |
| `events_of("CreatedPizza")` | Filter events by class name |
| `last_event` | Most recent event |
| `history` | Numbered event timeline |
| `commands` | List available commands with signatures |
| `reset!` | Clear all events and repository data |
| `reload!` | Recompile domain without leaving play mode |
| `extend :logging` | Apply an extension |

## Output

```
Pizza (3 attributes, 1 command)

Entering play mode

  Pizza.create(...)   # run a command
  Pizza.all           # list all
  Pizza.find(id)      # find by id
  events              # event log
  history             # numbered timeline
  reset!              # clear all data
  reload!             # re-read DSL, reboot runtime
  sketch!             # back to sketch mode

  Policy: NotifyKitchen -> PreparePizza

1. CreatedPizza at 2026-04-07 12:00:00 UTC
2. CreatedPizza at 2026-04-07 12:00:01 UTC

Cleared all events and data

Back to sketch mode
```

## Notes

- Calling `execute` in sketch mode auto-enters play mode
- `reload!` clears events and repository data on success; keeps the previous playground if validation fails
- Play mode uses memory adapters by default — use `extend` to swap in `:sqlite` or `:postgres`
- Aggregates are fully queryable in play mode: `find`, `all`, `count`, `where`
