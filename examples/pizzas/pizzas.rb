#!/usr/bin/env ruby
#
# Pizzas domain — generated from PizzasBluebook
#
# Run:  ruby -Ilib examples/pizzas/app.rb
#

require "hecks"

app = Hecks.boot(__dir__)


# Subscribe to events
app.on("CreatedPizza") do |event|
  puts "  [event] CreatedPizza: #{event.name}"
end

app.on("AddedTopping") do |event|
  puts "  [event] AddedTopping: #{event.name}"
end

app.on("PlacedOrder") do |event|
  puts "  [event] PlacedOrder: #{event.customer_name}"
end

app.on("CanceledOrder") do |event|
  puts "  [event] CanceledOrder"
end

puts "\n--- Running commands ---"

puts "\nCreating pizzas..."
pizza = Pizza.create(name: "Margherita", description: "Classic")

puts "\nAdd a measured topping via collection proxy..."
pizza.toppings.create(name: "Mozzarella", amount: 1)

puts "\nCreating orders..."
order = Order.place(customer_name: "Margherita", quantity: 1)

puts "\nCancel a pending order, transitioning status to cancelled..."
Order.cancel(order: order.id)

puts "\n--- Collection proxies ---"
pizza.toppings.create(name: "Margherita", amount: 1)
pizza.toppings.create(name: "Pepperoni", amount: 2)
puts "Pizza toppings: #{pizza.toppings.count}"
pizza.toppings.each do |item|
  puts "  - #{item.name} x#{item.amount}"
end
order.items.create(quantity: 1)
order.items.create(quantity: 2)
puts "Order items: #{order.items.count}"
order.items.each do |item|
  puts "  - x#{item.quantity}"
end

puts "\n--- Repository methods ---"
puts "Total pizzas: #{Pizza.count}"
found = Pizza.find(pizza.id)
puts "Found: #{found.name}"

Pizza.all.each do |item|
  puts "  #{item.name}: #{item.description}"
end

puts "\n--- Query objects ---"
results = Pizza.by_description("Margherita")
puts "ByDescription: #{results.map(&:name).join(", ")}"
results = Order.pending
puts "Pending: #{results.map(&:customer_name).join(", ")}"

# Value objects are immutable
item = PizzasDomain::Pizza::Topping.new(name: "Margherita", amount: 1)
puts "\nTopping: #{item.name} (frozen: #{item.frozen?})"

puts "\n--- Event history ---"
app.events.each_with_index do |event, i|
  name = event.class.name.split("::").last
  puts "#{i + 1}. #{name} at #{event.occurred_at}"
end
