#!/usr/bin/env ruby
#
# Example: Building and using a Pizzas domain with Hecks
#
# Run from the hecks project root:
#   ruby -Ilib examples/pizzas/app.rb

require "hecks"

# Boot the domain — loads Bluebook + Hecksagon, validates, builds, wires
app = Hecks.boot(__dir__)

# Subscribe to events
app.on("CreatedPizza") do |event|
  puts "  [event] CreatedPizza: #{event.name}"
end

app.on("PlacedOrder") do |event|
  puts "  [event] PlacedOrder: quantity=#{event.quantity}"
end

# 7. Run commands using the short API
puts "\n--- Running commands ---"

puts "\nCreating pizzas..."
margherita = Pizza.create(name: "Margherita", description: "Classic")
pepperoni = Pizza.create(name: "Pepperoni", description: "Spicy")

puts "\nPlacing an order..."
Order.place(pizza: margherita.id, customer_name: "Alice", quantity: 3)

# 8. Use collection proxies for toppings
puts "\n--- Collection proxies ---"
margherita.toppings.create(name: "Mozzarella", amount: 2)
margherita.toppings.create(name: "Basil", amount: 1)
puts "Margherita toppings: #{margherita.toppings.count}"
margherita.toppings.each do |t|
  puts "  - #{t.name} x#{t.amount}"
end

# 9. Use repository methods on the aggregate class
puts "\n--- Repository methods ---"
puts "Total pizzas: #{Pizza.count}"
found = Pizza.find(margherita.id)
puts "Found: #{found.name}"

Pizza.all.each do |p|
  puts "  #{p.name}: #{p.description}"
end

# 10. DSL query objects
puts "\n--- Query objects ---"
classics = Pizza.by_description("Classic")
puts "Classic pizzas: #{classics.map(&:name).join(", ")}"

spicy = Pizza.by_description("Spicy")
puts "Spicy pizzas: #{spicy.map(&:name).join(", ")}"

# 12. Value objects
topping = PizzasDomain::Pizza::Topping.new(name: "Pineapple", amount: 3)
puts "\nTopping: #{topping.name} x#{topping.amount} (frozen: #{topping.frozen?})"

# 13. Show event history
puts "\n--- Event history ---"
app.events.each_with_index do |event, i|
  name = event.class.name.split("::").last
  puts "#{i + 1}. #{name} at #{event.occurred_at}"
end
