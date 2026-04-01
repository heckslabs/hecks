# MCP-Compatible Runtime: Boot from IR

Load and run a domain without gem building, disk writes, or tmpdir.

## Hecks.load

```ruby
require "hecks"

domain = Hecks.domain "Pizzas" do
  aggregate "Pizza" do
    attribute :name, String
    command "CreatePizza" do
      attribute :name, String
    end
  end
end

runtime = Hecks.load(domain)
# => #<Hecks::Runtime ...>
# PizzasDomain is now defined in memory
```

With a custom event bus:

```ruby
bus = Hecks::EventBus.new
runtime = Hecks.load(domain, event_bus: bus)
mod = Object.const_get("PizzasDomain")
mod::Pizza.create(name: "Margherita")
```

## Workshop#execute

`execute` auto-enters play mode if not already active:

```ruby
workshop = Hecks::Workshop.new("Pizzas")
pizza = workshop.aggregate("Pizza")
pizza.attr :name, String
pizza.command("CreatePizza") { attribute :name, String }

# No need to call play! first
workshop.execute("CreatePizza", name: "Margherita")
# => #<PizzasDomain::Pizza ...>
workshop.play?  # => true
```

## MCP execute_command tool

The `execute_command` MCP tool automatically enters play mode before running,
removing the need for a separate `enter_play_mode` call:

```json
{ "tool": "execute_command", "command": "CreatePizza", "attrs": { "name": "Margherita" } }
```
