#!/usr/bin/env ruby

# A DRIVING ADAPTER, standing in for a real Stripe webhook handler — the
# same role a Rails controller would play (see docs/rails-integration.md's
# "Rails is a driving adapter, not a special one"), reduced to what's
# needed to demonstrate the shape without a real Stripe account. Boots
# Pizzas the normal way (bin/console's own path) and calls straight
# through Dispatcher#dispatch_port, exactly as a webhook controller would.
#
#   examples/pizzas/bluebook/hecksagon/mock_stripe_payment_adapter.rb
#
# LIVES BESIDE pizzas.hecksagon, DELIBERATELY — a `.hecksagon` file
# declares a port; a `hecksagon/` folder beside it holds the driving
# adapters that actually call one, the same pairing
# `lib/hecks/adapters/driven/` already has with `.adapter` files,
# mirrored for the opposite direction. Findable by walking there, not by
# knowing this file's name in advance.
#
# What this proves end to end: the port never touches Purchase's own
# business rules directly — it only translates an external fact
# ("this payment succeeded") into the domain's own event vocabulary
# (PizzaPaymentReceived), and OnPizzaPaymentReceived (pizzas.bluebook)
# is what actually triggers Purchase, given/then_set and all.

$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)

require "hecks"

DOMAIN  = File.expand_path("../..", __dir__)
RUNTIME = Hecks.boot(DOMAIN)

# Unique per run — this script is meant to be re-run freely, and identity
# here is never minted (see command_interpreter.rb's own "NOTHING IS
# MINTED"), so a repeat name is a repeat record, refused as AlreadyExists.
NAME = "StripeDemoMargherita-#{Process.pid}-#{rand(10_000)}"

# Set the stage: an order that's actually purchasable — Purchase's own
# `given` rules (at least one topping, still available) apply exactly the
# same whether reached directly or through this port.
order = Order.create_pizza(name: { value: NAME }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
order.add_topping(topping: { value: "Basil" }, amount: { value: 3 })

puts "Before payment: #{order.status}, customer=#{order.customer_name.inspect}"

# THE WEBHOOK — a real handler would verify a Stripe signature here and
# pull these fields out of event.data.object; a reference is always a bare
# id (never an object), matching every other reference in this language.
RUNTIME.dispatch_port(
  "Pizzas", "Order", "PaymentGateway", "Receive",
  name:          NAME,
  customer_name: { value: "Chris" },
  amount:        { cents: 1200 }
)

sold = Order.find(NAME)
puts "After payment:  #{sold.status}, customer=#{sold.customer_name.to_h}"
puts "Events: #{sold.events.map(&:name).join(', ')}"
