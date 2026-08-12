# Bug #74: Pizzas.Order.Purchase Accepts Underpayment

**Status:** IDENTIFIED

## The Bug

The Purchase command accepts payment amounts less than the pizza's price without validation.

**Evidence:**
- Pizza price: 1200 cents
- Payment accepted: 1000 cents
- Result: Order marked as sold despite underpayment

## Root Cause

The Purchase command has THREE given() predicates:
1. "a pizza needs at least one topping" — checks toppings.size.positive?
2. "it must still be available" — checks status == "available"
3. "a payment was actually made" — checks amount.cents.positive?

But there is NO predicate verifying that `amount >= pizza.price_cents`

## File Location

`examples/pizzas/bluebook/pizzas.bluebook`

Purchase command definition:
```ruby
command "Purchase" do
  role "Customer"
  goal "Buy the pizza"

  reference_to Order
  attribute :customer_name, CustomerName
  attribute :amount, Price

  given("a pizza needs at least one topping") { toppings.size.positive? }
  given("it must still be available")         { status == "available" }
  given("a payment was actually made")         { amount.cents.positive? }

  then_set :customer_name, to: :customer_name
  then_set :status,        to: "sold"

  emits "PizzaPurchased"
end
```

## The Fix

Add a predicate to verify payment is sufficient:

```ruby
command "Purchase" do
  role "Customer"
  goal "Buy the pizza"

  reference_to Order
  attribute :customer_name, CustomerName
  attribute :amount, Price

  given("a pizza needs at least one topping") { toppings.size.positive? }
  given("it must still be available")         { status == "available" }
  given("a payment was actually made")         { amount.cents.positive? }
  given("payment covers the price")           { amount.cents >= pizza.price_cents.cents }

  then_set :customer_name, to: :customer_name
  then_set :status,        to: "sold"

  emits "PizzaPurchased"
end
```

## Business Impact

HIGH - A customer can purchase a pizza while paying less than the asking price, resulting in revenue loss.

## Test Case

```ruby
# Create pizza with 1200 cent price
pizza = runtime.dispatch('Pizzas::Order.CreatePizza',
  name: { value: 'TestPizza' },
  pizza: { price_cents: { cents: 1200 }, size: { value: 'large' } }
)

# Add required topping
runtime.dispatch('Pizzas::Order.AddTopping',
  name: pizza.id,
  topping: { value: 'Pepperoni' },
  amount: { value: 100 }
)

# Attempt underpayment - currently succeeds, should fail
result = runtime.dispatch('Pizzas::Order.Purchase',
  name: pizza.id,
  customer_name: { value: 'Chris' },
  amount: { cents: 1000 }  # Less than 1200!
)

# Bug: result.state[:status] == "sold" (should have failed with GivenNotMet)
```

