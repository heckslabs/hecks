# Multi-Domain Go Target

Generate a Go project where each bounded context gets its own package.

## API

```ruby
require "hecks"

pizzas = Hecks.domain("Pizzas") do
  aggregate("Pizza") do
    attribute :name, String
    command("CreatePizza") { attribute :name, String }
  end
end

orders = Hecks.domain("Orders") do
  aggregate("Order") do
    attribute :quantity, Integer
    command("PlaceOrder") { attribute :quantity, Integer }
  end
end

# Generate multi-domain Go project
root = Hecks.build_go_multi([pizzas, orders], name: "my_platform")
```

## Output structure

```
my_platform_static_go/
  go.mod                          # module my_platform
  runtime/
    eventbus.go                   # shared EventBus
    commandbus.go                 # shared CommandBus
  pizzas/                         # package pizzas
    pizza.go
    create_pizza.go
    pizza_repository.go
    errors.go
    adapters/memory/
      pizza_repository.go
  orders/                         # package orders
    order.go
    place_order.go
    order_repository.go
    errors.go
    adapters/memory/
      order_repository.go
  server/
    server.go                     # combined server routing both domains
  cmd/main/
    main.go
```

## Routes

Each domain's aggregates are prefixed by domain name:

```
GET  /pizzas/pizzas              # list all pizzas
GET  /pizzas/pizzas/find?id=...  # find a pizza
POST /pizzas/pizzas/create_pizza/submit

GET  /orders/orders              # list all orders
POST /orders/orders/place_order/submit
```

## Options

| Parameter    | Default          | Description                        |
|-------------|------------------|------------------------------------|
| `output_dir` | `"."`           | Parent directory for output        |
| `name`       | `"multi_domain"` | Project name (affects module path) |
