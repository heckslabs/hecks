# CRUD Capability

The CRUD capability generates Create, Update, and Delete command stubs for
every aggregate in your domain. User-defined commands always take precedence --
if you already defined `CreatePizza` in your Bluebook, the capability skips it.

## Enabling CRUD

```ruby
# In app.rb
app = Hecks.boot(__dir__)
app.capability(:crud)
```

CRUD is a **capability**, not a DSL keyword. The Bluebook stays pure domain
structure; the hecksagon enriches it at runtime.

## What gets generated

For an aggregate `Pizza` with attributes `name` and `style`:

| Command       | Attributes                  | Reference     |
|---------------|-----------------------------|---------------|
| CreatePizza   | name, style                 | --            |
| UpdatePizza   | name, style                 | pizza (self)  |
| DeletePizza   | --                          | pizza (self)  |

`ReadPizza` is not generated -- repository methods (`.find`, `.all`, `.count`,
`.first`, `.last`) handle reads directly.

## Skipping user-defined commands

```ruby
# Bluebook -- pure domain
Hecks.domain "Pizzas" do
  aggregate "Pizza" do
    attribute :name, String
    attribute :style, String

    command "CreatePizza" do
      attribute :name, String  # only name, not style
    end
  end
end

# Hecksagon
app = Hecks.boot(__dir__)
app.capability(:crud)
# CreatePizza is user-defined (kept as-is)
# UpdatePizza and DeletePizza are generated
```

## Using generated commands

```ruby
# Create (user-defined or generated)
pizza = Pizza.create(name: "Margherita", style: "Classic")

# Update (generated)
Pizza.update(pizza: pizza.id, name: "Updated Name", style: "New Style")

# Delete (generated)
Pizza.delete(pizza: pizza.id)

# Repository reads (always available)
Pizza.find(pizza.id)
Pizza.all
Pizza.count
Pizza.first
Pizza.last
```

## Without CRUD capability

Without calling `app.capability(:crud)`, only user-defined commands exist.
Repository methods (`find`, `all`, `count`) are always bound by the runtime
regardless of the CRUD capability.

## Integration points

- **Workshop**: CRUD is auto-enabled in play mode
- **Rails (Hecks.configure)**: CRUD is auto-enabled at boot
- **hecks new**: Generated `app.rb` includes `app.capability(:crud)`
