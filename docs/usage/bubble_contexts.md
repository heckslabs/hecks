# Bubble Contexts — Anti-Corruption Layer

Bubble contexts provide an ACL (Anti-Corruption Layer) for translating
legacy or external system data into clean domain commands. Field renames,
value transforms, and reverse mappings keep integration code out of
your domain model.

## Setup

```ruby
require "hecks/extensions/bubble"
```

## Defining a Context

```ruby
ctx = HecksBubble::Context.new do
  map_aggregate :Pizza do
    from_legacy :create,
      rename: { pizza_nm: :name, desc_text: :description },
      transform: { name: ->(v) { v.strip.capitalize } }

    map_out :create,
      rename: { name: :pizza_nm, description: :desc_text }
  end
end
```

## Translating Inbound Data

```ruby
ctx.translate(:Pizza, :create, pizza_nm: "  margherita ", desc_text: "Classic")
# => { name: "Margherita", description: "Classic" }
```

Fields are renamed first, then transforms are applied on the renamed keys.
Unmapped fields pass through unchanged.

## Reverse Mapping (Outbound)

```ruby
ctx.reverse(:Pizza, :create, name: "Margherita", description: "Classic")
# => { pizza_nm: "Margherita", desc_text: "Classic" }
```

## Using with a Domain Module

When the `:bubble` extension is registered, each domain module gets
`bubble_context` and `bubble` methods:

```ruby
app = Hecks.boot(__dir__)

PizzasDomain.bubble_context do
  map_aggregate :Pizza do
    from_legacy :create,
      rename: { pizza_nm: :name },
      transform: { name: ->(v) { v.strip.capitalize } }
  end
end

# Translate legacy API payload into a domain command
clean = PizzasDomain.bubble.translate(:Pizza, :create, pizza_nm: " pepperoni ")
Pizza.create(**clean)
```

## Multiple Aggregates

```ruby
ctx = HecksBubble::Context.new do
  map_aggregate :Pizza do
    from_legacy :create, rename: { nm: :name }
  end

  map_aggregate :Order do
    from_legacy :place, rename: { qty: :quantity, cust: :customer_name }
  end
end

ctx.translate(:Pizza, :create, nm: "Hawaiian")
# => { name: "Hawaiian" }

ctx.translate(:Order, :place, qty: 3, cust: "Alice")
# => { quantity: 3, customer_name: "Alice" }
```

## Introspection

```ruby
ctx.mapped_aggregates  # => [:Pizza, :Order]
ctx.mapper_for(:Pizza) # => HecksBubble::AggregateMapper
```
