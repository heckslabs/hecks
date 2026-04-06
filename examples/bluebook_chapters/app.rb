#!/usr/bin/env ruby
#
# Example: Bluebook with Chapters — composed multi-domain
#
# A single Bluebook defines three chapters (domains). Cross-chapter
# policies wire events across boundaries automatically. When an order
# is placed, billing creates an invoice and shipping creates a shipment.
#
# Run from the hecks project root:
#   ruby -Ilib examples/bluebook_chapters/app.rb

require "hecks"

# Define the entire system in one Bluebook
book = Hecks.bluebook "PizzaShop" do
  chapter "Pizzas" do
    aggregate "Pizza" do
      attribute :name, String
      attribute :style, String
      attribute :price, Float

      command "CreatePizza" do
        attribute :name, String
        attribute :style, String
        attribute :price, Float
      end
    end

    aggregate "Order" do
      reference_to "Pizza"
      attribute :quantity, Integer

      command "PlaceOrder" do
        reference_to "Pizza", validate: false
        attribute :quantity, Integer
      end
    end
  end

  chapter "Billing" do
    aggregate "Invoice" do
      attribute :quantity, Integer
      attribute :status, String

      command "CreateInvoice" do
        attribute :quantity, Integer
      end
    end

    policy "AutoInvoice" do
      on "PlacedOrder"
      trigger "CreateInvoice"
      map quantity: :quantity
    end
  end

  chapter "Shipping" do
    aggregate "Shipment" do
      attribute :quantity, Integer

      command "CreateShipment" do
        attribute :quantity, Integer
      end
    end

    policy "AutoShip" do
      on "PlacedOrder"
      trigger "CreateShipment"
      map quantity: :quantity
    end
  end
end

# Boot all chapters with shared event bus
runtimes = Hecks.open(book)
shared_bus = Hecks.shared_event_bus

# Watch cross-chapter events
shared_bus.subscribe("PlacedOrder")    { |e| puts "  [event] PlacedOrder: quantity=#{e.quantity}" }
shared_bus.subscribe("CreatedInvoice") { |e| puts "  [event] CreatedInvoice: quantity=#{e.quantity}" }
shared_bus.subscribe("CreatedShipment"){ |e| puts "  [event] CreatedShipment: quantity=#{e.quantity}" }

# Create a pizza and place an order
puts "\n--- Creating a pizza ---"
margherita = PizzasDomain::Pizza.create(name: "Margherita", style: "Classic", price: 12.0)
puts "Created: #{margherita.name} ($#{margherita.price})"

puts "\n--- Placing an order ---"
puts "Watch events flow across all three chapters:"
PizzasDomain::Order.place(pizza: margherita.id, quantity: 3)

# Check state across chapters
puts "\n--- Cross-chapter state ---"
puts "Pizzas:    #{PizzasDomain::Pizza.count}"
puts "Orders:    #{PizzasDomain::Order.count}"
puts "Invoices:  #{BillingDomain::Invoice.count}"
puts "Shipments: #{ShippingDomain::Shipment.count}"

# Show shared event history
puts "\n--- Shared event history ---"
shared_bus.events.each_with_index do |event, i|
  name = event.class.name.split("::").last
  puts "#{i + 1}. #{name} at #{event.occurred_at}"
end
