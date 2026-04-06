# Bluebook Chapters

Compose multiple domains into a single system using the Bluebook/Chapter metaphor.

## Quick Start

```ruby
require "hecks"

book = Hecks.bluebook "PizzaShop" do
  chapter "Pizzas" do
    aggregate "Pizza" do
      attribute :name, String
      command("CreatePizza") { attribute :name, String }
    end
  end

  chapter "Billing" do
    aggregate "Invoice" do
      attribute :amount, Float
      command("CreateInvoice") { attribute :amount, Float }
    end
  end
end

runtimes = Hecks.open(book)
```

## Cross-Chapter Policies

Chapters share an event bus. Policies in one chapter can react to events from another:

```ruby
Hecks.bluebook "Shop" do
  chapter "Orders" do
    aggregate "Order" do
      attribute :quantity, Integer
      command("PlaceOrder") { attribute :quantity, Integer }
    end
  end

  chapter "Shipping" do
    aggregate "Shipment" do
      attribute :quantity, Integer
      command("CreateShipment") { attribute :quantity, Integer }
    end

    policy "AutoShip" do
      on "PlacedOrder"
      trigger "CreateShipment"
      map quantity: :quantity
    end
  end
end
```

## Workshop Mode

Build chapters interactively in the Workshop:

```ruby
workshop = Hecks.workshop("MyApp")
workshop.chapter("Orders") do
  aggregate("Order") { attribute :total, Float; command("PlaceOrder") { attribute :total, Float } }
end
workshop.chapter("Billing") do
  aggregate("Invoice") { attribute :amount, Float; command("CreateInvoice") { attribute :amount, Float } }
end
workshop.play!   # boots all chapters with shared event bus
```

## Binding (Spine)

The binding is the spine that holds chapters together. It models bootstrap
infrastructure: module wiring, registries, error hierarchies, and cross-chapter
event routing.

```ruby
Hecks.bluebook "MyApp" do
  binding "Infrastructure" do
    aggregate "EventRouter" do
      attribute :source_chapter, String
      command("RouteEvent") { attribute :event_name, String }
    end
  end

  chapter "Orders" do
    aggregate "Order" do
      attribute :name, String
      command("PlaceOrder") { attribute :name, String }
    end
  end
end
```

The binding is accessible on the IR: `bluebook.binding` returns a Domain, while
`bluebook.chapters` returns the array of chapter Domains.

Hierarchy: **bluebook > binding > chapters**

## Self-Describing Architecture

Hecks itself is a Bluebook. Every module is expressed as a chapter using the
same DSL it provides to users:

```ruby
require "hecks"
load "HecksBluebook"

bb = Hecks::Chapters.bluebook
bb.binding.name           # => "Binding"
bb.chapters.map(&:name)
# => ["Bluebook", "Runtime", "Workshop", "Hecksagon", "Targets",
#     "Cli", "Extensions", "Ai", "Rails"]
```

## Boot Detection

`Hecks.boot(__dir__)` auto-detects Bluebook files. Place a single file using `Hecks.bluebook`:

```ruby
# AppBluebook
Hecks.bluebook "MyApp" do
  chapter "Catalog" do ... end
  chapter "Sales" do ... end
end
```

Then boot:

```ruby
runtimes = Hecks.boot(__dir__)
```

## Configuration

`Hecks.configure` accepts `chapter` as an alias for `domain`:

```ruby
Hecks.configure do
  chapter "pizzas_domain"
  chapter "billing_domain" do
    listens_to "pizzas_domain"
  end
  adapter :sqlite
end
```

## Shared Event Bus

Access the shared bus after booting:

```ruby
runtimes = Hecks.open(book)
bus = Hecks.shared_event_bus
bus.subscribe("CreatedInvoice") { |e| puts e.amount }
```

## Run the Example

```sh
ruby -Ilib examples/bluebook_chapters/app.rb
```
