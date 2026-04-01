# View Contracts & Smoke Test

## View Contracts

Shared data shape definitions for the web explorer views. Each contract
defines the fields, types, and nested structs a template expects. Go struct
generation and Go template conversion both use these contracts to prevent
field name drift.

```ruby
require "hecks_templating"

# See all contracts
Hecks::ViewContract.all.keys  # => [:layout, :home, :index, :show, :form, :config]

# Inspect a contract
Hecks::ViewContract::INDEX[:fields]
# => [{name: :aggregate_name, type: :string}, {name: :items, type: :list, item_type: :index_item}, ...]

# Generate a Go struct from a contract
Hecks::ViewContract.go_struct(:index_item, Hecks::ViewContract::INDEX[:structs][:index_item], prefix: "Pizza")
# => "type PizzaIndexItem struct { Id string; ShortId string; ShowHref string; Cells []string; RowActions []RowAction }"
```

## Smoke Test

Domain-driven HTTP smoke test that exercises every web explorer page.
Works against both Ruby and Go targets.

```ruby
require "hecks_templating"

smoke = HecksTemplating::SmokeTest.new("http://localhost:9292", domain)
results = smoke.run
# OK   GET  /
# OK   GET  /config
# OK   GET  /pizzas
# OK   GET  /pizzas/create_pizza/new
# OK   POST /pizzas/create_pizza
# OK   GET  /pizzas/show?id=abc123
# ...
# 12 passed, 0 failed (12 total)
```

The smoke test runs automatically after `Hecks.build_go`. To skip it:

```ruby
Hecks.build_go(domain, output_dir: ".", smoke_test: false)
```
