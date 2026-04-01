# deep_inspect — Full Structural Breakdown

The `deep_inspect` command prints a detailed tree of every element in your
domain: aggregates, attributes, value objects, entities, commands with
parameters, events, policies, validations, queries, scopes, specifications,
subscribers, and references.

## Usage

```ruby
workshop = Hecks.workshop("Pizzas")

workshop.aggregate "Pizza" do
  attribute :name, String
  attribute :style, String

  value_object "Topping" do
    attribute :name, String
    attribute :quantity, Integer
  end

  command "CreatePizza" do
    attribute :name, String
    attribute :style, String
  end

  command "RenamePizza" do
    attribute :name, String
  end

  validation :name, presence: true
  query "ByStyle" do |style| { style: style } end
  scope :classic, style: "classic"
end

# Inspect the full domain
workshop.deep_inspect

# Inspect a single aggregate
workshop.deep_inspect("Pizza")
```

## Example Output

```
Pizzas Domain

  Pizza
    name: String
    style: String
    [value_object] Topping
      name: String
      quantity: Integer
    [command] CreatePizza
      name: String
      style: String
      -> emits CreatedPizza
    [command] RenamePizza
      name: String
      -> emits RenamedPizza
    [event] CreatedPizza(name: String, style: String)
    [event] RenamedPizza(name: String)
    [query] ByStyle
    [validation] name: presence: true
    [scope] classic
```

## Architecture

`deep_inspect` is built on two composable components:

- **Navigator** — walks the domain IR tree, yielding each element with its
  depth and label. Use it to build custom traversals.
- **Renderer** — formats each IR element into a human-readable string.
  Swap it out for JSON, HTML, or any other format.

```ruby
domain = workshop.to_domain
navigator = Hecks::Workshop::Navigator.new(domain)
renderer  = Hecks::Workshop::Renderer.new

navigator.walk_all do |element, depth, label|
  puts renderer.render(element, depth: depth, label: label)
end
```
