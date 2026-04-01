# emits — Named Domain Events

The `emits` keyword lets commands declare explicit event names instead of
relying on automatic past-tense conjugation. It also supports multiple events
per command.

## Without emits (default)

Event names are inferred by converting the leading verb to past tense:

```ruby
command "CreatePizza" do
  attribute :name, String
end
# emits CreatedPizza automatically
```

## Single explicit event name

Override the inferred name with any PascalCase string:

```ruby
command "CreatePizza" do
  attribute :name, String
  emits "PizzaCreated"
end
# emits PizzaCreated instead of CreatedPizza
```

This is useful when your team prefers noun-first event names or when the
inferred conjugation is wrong for a domain-specific verb.

## Multiple events per command

A single command can emit more than one event:

```ruby
command "CreatePizza" do
  attribute :name, String
  emits "PizzaCreated", "MenuUpdated"
end
# emits both PizzaCreated and MenuUpdated
```

All events are published to the event bus, so policies and subscribers can
react to any of them independently.

## Runtime access

```ruby
cmd = PizzasDomain::Pizza.create(name: "Margherita")

cmd.event    # => first emitted event (backward compat)
cmd.events   # => [PizzaCreated, MenuUpdated] — all events
```

## Policies reacting to named events

Policies work the same way — just reference the explicit name:

```ruby
policy "AutoReady" do
  on "PizzaCreated"
  trigger "MarkReady"
end
```

## Serializer round-trip

The DSL serializer preserves `emits` declarations:

```ruby
Hecks::DslSerializer.new(domain).serialize
# => includes:  emits "PizzaCreated", "MenuUpdated"
```

## Running examples

```ruby
domain = Hecks.domain "Pizzas" do
  aggregate "Pizza" do
    attribute :name, String

    command "CreatePizza" do
      attribute :name, String
      emits "PizzaCreated", "MenuUpdated"
    end
  end
end

app = Hecks.load(domain)
cmd = PizzasDomain::Pizza.create(name: "Margherita")

puts cmd.events.map { |e| e.class.name.split("::").last }.inspect
# => ["PizzaCreated", "MenuUpdated"]

puts app.events.size
# => 2
```
