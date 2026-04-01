# ActiveHecks — Rails Integration Layer

ActiveHecks bridges generated Hecks domain objects and Rails. It adds ActiveModel compatibility so your domain objects work with forms, validations, JSON serialization, and lifecycle callbacks — without polluting the domain gem itself.

## How It Works

```mermaid
flowchart LR
    subgraph Domain["Domain Gem"]
        Pizza["Pizza\n(Hecks::Model)"]
        Topping["Pizza::Topping\n(value object)"]
        Cmd["CreatePizza\n(Hecks::Command)"]
    end

    subgraph ActiveHecks["ActiveHecks.activate"]
        DM["DomainModelCompat\n(naming, JSON, conversion)"]
        AC["AggregateCompat\n(identity, validations, callbacks)"]
        VO["ValueObjectCompat\n(no identity, immutable)"]
        VW["ValidationWiring\n(DSL rules → validates)"]
        PW["PersistenceWrapper\n(save guards + callbacks)"]
    end

    subgraph Rails["Rails"]
        Forms["form_for / form_with"]
        JSON["as_json / to_json"]
        Ctrl["Controllers"]
    end

    Pizza --> DM & AC
    AC --> VW & PW
    Topping --> DM & VO
    DM --> Forms & JSON
    PW --> Ctrl
```

## Activation

One call wires everything up:

```ruby
# In a Rails initializer or after Hecks.configure
ActiveHecks.activate(PizzasDomain)

# Or pass the domain IR for validation wiring from the DSL definition:
ActiveHecks.activate(PizzasDomain, domain: domain_obj)
```

This walks every class in the domain module and includes the right mixins:
- **Aggregates** get full ActiveModel support (validations, callbacks, persistence guards)
- **Value objects** get naming and serialization only (they're frozen, so no validations)

The walker handles nested modules — if your domain groups aggregates under sub-modules, it recurses into them (skipping `Ports` and `Adapters`). It uses `constants(false)` when scanning for nested value objects, so inherited constants from included modules (like ActiveModel validators) are ignored. It strips the domain module prefix from `model_name` so `PizzasDomain::Pizza` reports as just `"Pizza"`.

With Rails, activation happens automatically via the Railtie — just call `Hecks.configure` in an initializer.

## Mixin Architecture

```mermaid
classDiagram
    class DomainModelCompat {
        +to_model()
        +attributes()
        +read_attribute_for_serialization()
        ActiveModel::Naming
        ActiveModel::Conversion
        ActiveModel::Serializers::JSON
    }

    class AggregateCompat {
        +persisted?()
        +new_record?()
        +destroyed?()
        +to_param()
        +to_key()
        ActiveModel::Validations
        ActiveModel::Callbacks
    }

    class ValueObjectCompat {
        +persisted?() false
        +new_record?() true
        +destroyed?() false
        +to_param() nil
    }

    class ValidationWiring {
        +bind(klass, domain:)$
        DSL rules → validates calls
    }

    class PersistenceWrapper {
        +bind(klass)$
        save() checks valid? first
        save!() raises on invalid
        destroy() runs callbacks
    }

    DomainModelCompat <|-- AggregateCompat : aggregates include both
    DomainModelCompat <|-- ValueObjectCompat : VOs include both
    AggregateCompat --> ValidationWiring : wired during activate
    AggregateCompat --> PersistenceWrapper : wired during activate
```

### DomainModelCompat

Shared by all domain objects. Adds:
- `ActiveModel::Naming` — `Pizza.model_name` works
- `ActiveModel::Conversion` — `to_model`, `to_partial_path`
- `ActiveModel::Serializers::JSON` — `as_json`, `to_json`
- `attributes` — uses `hecks_attributes` metadata from `Hecks::Model`, falling back to constructor parameters, plus `id`, `created_at`, `updated_at`

### AggregateCompat

Aggregates only. Adds:
- `ActiveModel::Validations` — `valid?`, `errors`
- `ActiveModel::Callbacks` — `before_save`, `after_create`, etc.
- Model callbacks defined for `:save`, `:create`, `:update`, `:destroy`
- Identity methods — `persisted?` (true when `id` is not nil), `new_record?`, `to_param`, `to_key`

### ValueObjectCompat

Value objects only. Lightweight — no validations (frozen objects can't mutate `@errors`):
- Always `persisted? → false`, `new_record? → true`, `destroyed? → false`
- `to_param → nil`, `to_key → nil`

### ValidationWiring

Converts DSL validation rules into ActiveModel `validates` calls. Looks for validations in two places: the class's `domain_def` accessor (set by introspection during wiring), or a passed `domain:` IR object:

```ruby
# DSL definition:
validation :name, presence: true

# Becomes at activation time:
Pizza.validates :name, presence: true
```

This also disables the domain-level `validate!` (which raises in the constructor) so you can build invalid objects and check `valid?` / `errors` the Rails way. `check_invariants!` is not disabled — invariants are structural constraints that still run at construction time.

### PersistenceWrapper

Wraps `save` and `destroy` with validation checks and callbacks. Only binds if the class already has a `save` method (i.e., RepositoryMethods is wired):

```ruby
pizza.save     # => false if invalid (won't hit the adapter)
pizza.save!    # => raises ActiveModel::ValidationError if invalid
pizza.destroy  # => runs :destroy callbacks, then delegates
```

## Usage in Rails

```ruby
# config/initializers/hecks.rb
Hecks.configure do
  domain "pizzas_domain"
  adapter :sql, database: :postgres, host: "localhost", name: "pizzas"
end

# app/controllers/pizzas_controller.rb
class PizzasController < ApplicationController
  def create
    pizza = Pizza.new(pizza_params)
    if pizza.save
      redirect_to pizza
    else
      render :new  # pizza.errors works with form helpers
    end
  end
end
```

## What a Domain Object Looks Like

With `Hecks::Model`, domain objects are minimal. ActiveHecks layers Rails compatibility on top without touching the domain:

```ruby
# Generated domain gem — pure Ruby, no Rails
class Pizza
  include Hecks::Model

  attribute :name
  attribute :description
  attribute :toppings, default: [], freeze: true
end

# Hecks::Model auto-creates submodules: Commands, Events, Queries, Policies
# These use const_missing for autoloading by convention:
#   Pizza::Commands::CreatePizza  → pizzas_domain/pizza/commands/create_pizza.rb
#   Pizza::Events::CreatedPizza   → pizzas_domain/pizza/events/created_pizza.rb

# After ActiveHecks.activate — gains Rails powers:
pizza = Pizza.new(name: "")
pizza.valid?          # => false
pizza.errors[:name]   # => ["can't be blank"]
pizza.as_json         # => {"id" => "...", "name" => "", ...}
```

## Rails Generators

### `rails generate active_hecks:init`

One command sets up everything:

1. **Gem** — adds `hecks_on_rails` to Gemfile
2. **Domain detection** — finds `*_domain` gems (local directories or installed)
3. **Initializer** — `config/initializers/hecks.rb`
4. **README** — `app/models/HECKS_README.md` explaining the setup
5. **Test helper** — injects `require "hecks/test_helper"` into spec/test helpers
6. **HecksLive** — runs `active_hecks:live` automatically (see below)

### `rails generate active_hecks:live`

Sets up real-time domain event streaming:

1. Enables ActionCable in `config/application.rb`
2. Creates `config/cable.yml` and channel files
3. Mounts ActionCable at `/cable`
4. Pins `@hotwired/turbo-rails` via importmap
5. Adds `action_cable_meta_tag` and `turbo_stream_from "hecks_live_events"` to layout

### `rails generate active_hecks:migration`

Compares the current domain against a saved snapshot (`.hecks_domain_snapshot.rb`), diffs them with `DomainDiff`, and generates incremental SQL migration files to `db/hecks_migrate/` — separate from ActiveRecord migrations.

## Railtie

The Railtie handles three things automatically:

1. **Boot** — detects already-booted domain gems or boots them via `Hecks.configure`
2. **Live events** — wires `event_bus.on_any` to `Turbo::StreamsChannel` for real-time broadcasting
3. **Rake tasks**:
   - `rake hecks:generate:migrations` — diff domain snapshots, generate SQL
   - `rake hecks:db:migrate` — run pending Hecks SQL migrations

### URL Helper Compatibility

Command results (from `Pizza.create`, etc.) work with Rails URL helpers:

```ruby
pizza = Pizza.create(name: "Margherita")
admin_pizza_path(pizza)  # works — ActiveHecks patches to_param on command classes
```

## What Stays Out of the Domain

ActiveHecks is separate from the domain gem by design. The generated gem uses `Hecks::Model`, `Hecks::Command`, and `Hecks::Query` — pure Ruby with no framework dependency. ActiveHecks adds Rails compatibility from the outside. The domain never knows.

| Concern | Domain Gem | ActiveHecks |
|---|---|---|
| Attributes (via DSL) | `Hecks::Model` | — |
| Business invariants | `validate!` / `check_invariants!` | disables `validate!` only |
| Commands | `Hecks::Command` (mixin) | — |
| Queries | `Hecks::Query` (mixin) | — |
| ActiveModel naming | — | DomainModelCompat |
| JSON serialization | — | DomainModelCompat |
| Validations (`valid?`) | — | AggregateCompat + ValidationWiring |
| Lifecycle callbacks | — | AggregateCompat |
| Save/destroy guards | — | PersistenceWrapper |
| Form helpers | — | DomainModelCompat + AggregateCompat |
