# Bug #75: Pizzas.Order.CreatePizza Accepts Negative Prices

**Status:** IDENTIFIED

## The Bug

The CreatePizza command accepts negative price_cents values without validation, allowing prices like -1000.

**Evidence:**
```ruby
pizza = runtime.dispatch('Pizzas::Order.CreatePizza',
  name: { value: 'NegativePizza' },
  pizza: { price_cents: { cents: -1000 }, size: { value: 'large' } }
)
# Result: Pizza created successfully with price: -1000
```

## Root Cause

The CreatePizza command has no predicate to validate that price_cents is positive. The Price VO declares an invariant `cents.positive?` but CreatePizza is a creating command, and creating commands bypass some runtime validation steps in the current implementation.

## File Location

`examples/pizzas/bluebook/pizzas.bluebook` (lines 50-60 approx)

```ruby
command "CreatePizza" do
  role "Customer"
  goal "Create a pizza with a name and starting price"

  attribute :name,  PizzaName
  attribute :pizza, Pizza

  then_set :name,  to: :name
  then_set :pizza, to: :pizza

  emits "PizzaCreated"
end
```

## The Fix

Add a predicate to ensure positive price:

```ruby
command "CreatePizza" do
  role "Customer"
  goal "Create a pizza with a name and starting price"

  attribute :name,  PizzaName
  attribute :pizza, Pizza

  given("pizza price must be positive") { pizza.price_cents.cents.positive? }

  then_set :name,  to: :name
  then_set :pizza, to: :pizza

  emits "PizzaCreated"
end
```

## Business Impact

HIGH - A pizza with negative price violates business logic and could allow customers to be paid to order pizzas (arbitrage).

## Related Issues

- Bug #74 (underpayment) - if a pizza can have negative price, underpayment validation becomes even more critical

