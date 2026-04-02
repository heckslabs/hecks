# Hecksagon DSL

The Hecksagon file declares infrastructure capabilities alongside the Bluebook.
The Bluebook describes pure domain structure. The Hecksagon says what to do with it.

## Two-File Pattern

```ruby
# PizzasBluebook — pure domain
Hecks.domain "Pizzas" do
  aggregate "Pizza" do
    attribute :name, String
    attribute :email, String
    command "CreatePizza" do
      attribute :name, String
    end
  end
end

# PizzasHecksagon — infrastructure capabilities
Hecks.hecksagon "Pizzas" do
  capabilities :crud
end
```

## Auto-Discovery

`Hecks.boot(__dir__)` discovers both `*Bluebook` and `*Hecksagon` files
in the project directory and loads them automatically.

## Domain-Wide Capabilities

```ruby
Hecks.hecksagon "Pizzas" do
  capabilities :crud, :audit
end
```

Capabilities are visitors over the domain IR that generate constructs.
`:crud` generates Create/Read/Update/Delete command stubs on every aggregate,
skipping any command the user already defined in the Bluebook.

## Per-Aggregate Capabilities

```ruby
Hecks.hecksagon "Healthcare" do
  capabilities :crud

  aggregate "Patient" do
    capability.email.pii
    capability.ssn.pii
  end
end
```

`capability.email.pii` tags the `email` attribute on `Patient` with the `:pii`
capability. Capabilities self-activate from usage — no separate `concern :pii`
declaration needed.

## How It Works

- The domain is the structural index (the skeleton)
- Capabilities are the muscles — visitors that attach behavior to domain nodes
- The hecksagon is sparse: it only tags nodes that need infrastructure
- `aggregate "Patient"` in the hecksagon doesn't create anything — it points
  to the domain node

## Running Example

```sh
ruby -Ilib examples/pizzas/app.rb
```
