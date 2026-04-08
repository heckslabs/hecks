#!/usr/bin/env ruby
#
# Example: Multiple domains sharing an event bus
#
# Three separate domains — pizzas, billing, shipping — each with their
# own aggregates and commands. When an order is placed in pizzas, billing
# creates an invoice and shipping creates a shipment via reactive policies.
#
# Run from the hecks project root:
#   ruby -Ilib examples/multi_domain/app.rb

require "hecks"

# Boot all domains from hecks/ subfolder with shared event bus
apps = Hecks.boot(__dir__)

# Access the shared inner bus for cross-domain event observation
shared_bus = Hecks.shared_event_bus

# Subscribe to events across all domains
shared_bus.subscribe("PlacedOrder") do |event|
  puts "  [event] PlacedOrder: quantity=#{event.quantity}"
end

shared_bus.subscribe("CreatedInvoice") do |event|
  puts "  [event] CreatedInvoice: quantity=#{event.quantity}"
end

shared_bus.subscribe("CreatedShipment") do |event|
  puts "  [event] CreatedShipment: quantity=#{event.quantity}"
end

# Create a pizza and place an order
puts "\n--- Creating a pizza ---"
margherita = Pizza.create(name: "Margherita", style: "Classic", price: 12.0)
puts "Created: #{margherita.name} ($#{margherita.price})"

puts "\n--- Placing an order ---"
puts "Watch what happens across all three domains:"
Order.place(pizza: margherita.id, quantity: 3)

# Check pizzas domain state
puts "\n--- Pizzas domain ---"
puts "Pizzas: #{Pizza.count}"
puts "Orders: #{Order.count}"

# Show the shared event history — events flow across all domains
puts "\n--- Shared event history ---"
shared_bus.events.each_with_index do |event, i|
  name = event.class.name.split("::").last
  puts "#{i + 1}. #{name} at #{event.occurred_at}"
end
