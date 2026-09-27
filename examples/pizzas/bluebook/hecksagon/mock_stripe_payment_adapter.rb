#!/usr/bin/env ruby

# Driving adapter standing in for a Stripe webhook handler: boots Pizzas and calls
# Dispatcher#dispatch_port, which translates the payment into PizzaPaymentReceived.
#
#   examples/pizzas/bluebook/hecksagon/mock_stripe_payment_adapter.rb

$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)

require "hecks"

DOMAIN  = File.expand_path("../..", __dir__)
RUNTIME = Hecks.boot(DOMAIN)

# Unique per run: identity is never minted, so a repeated name would be refused as AlreadyExists.
NAME = "StripeDemoMargherita-#{Process.pid}-#{rand(10_000)}".freeze

# Set the stage: an order Purchase's `given` rules will accept.
order = Order.create_pizza(name: { value: NAME }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
order.add_topping(topping: { value: "Basil" }, amount: { value: 3 })

puts "Before payment: #{order.status}, customer=#{order.customer_name.inspect}"

# The webhook: a real handler would verify a Stripe signature; a reference is always a bare id.
RUNTIME.dispatch_port(
  "Pizzas", "Order", "PaymentGateway", "Receive",
  flat: {
    name:          NAME,
    customer_name: { value: "Chris" },
    amount:        { cents: 1200 }
  }
)

sold = Order.find(NAME)
puts "After payment:  #{sold.status}, customer=#{sold.customer_name.to_h}"
puts "Events: #{sold.events.map(&:name).join(', ')}"
