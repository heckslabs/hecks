require "spec_helper"
require "tmpdir"

RSpec.describe "Multi-domain with shared event bus" do
  let(:pizzas_domain) do
    Hecks.domain "Pizzas" do
      aggregate "Pizza" do
        attribute :name, String

        command "CreatePizza" do
          attribute :name, String
        end
      end

      aggregate "Order" do
        reference_to "Pizza"
        attribute :quantity, Integer

        command "PlaceOrder" do
          reference_to "Pizza"
          attribute :quantity, Integer
        end
      end
    end
  end

  let(:billing_domain) do
    Hecks.domain "Billing" do
      aggregate "Invoice" do
        attribute :pizza, String
        attribute :quantity, Integer

        command "CreateInvoice" do
          attribute :pizza, String
          attribute :quantity, Integer
        end

        policy "BillOnOrder" do
          on "PlacedOrder"
          trigger "CreateInvoice"
        end
      end
    end
  end

  before do
    shared_bus = Hecks::EventBus.new
    @pizzas_app = Hecks.load(pizzas_domain, event_bus: shared_bus)
    @billing_app = Hecks.load(billing_domain, event_bus: shared_bus)
  end

  it "each domain has its own aggregates" do
    pizza = PizzasDomain::Pizza.create(name: "Margherita")
    expect(pizza.name).to eq("Margherita")

    invoice = BillingDomain::Invoice.create(pizza: "abc", quantity: 1)
    expect(invoice.pizza).to eq("abc")
  end

  it "shares events across domains via the event bus" do
    pizza = PizzasDomain::Pizza.create(name: "Margherita")
    seed = PizzasDomain::Order.new(id: pizza.id, pizza: pizza.id, quantity: 1)
    seed.save
    PizzasDomain::Order.place(pizza: pizza.id, quantity: 3)

    # PlacedOrder event should be visible to both apps
    pizza_events = @pizzas_app.events.map { |e| e.class.name.split("::").last }
    billing_events = @billing_app.events.map { |e| e.class.name.split("::").last }

    expect(pizza_events).to include("PlacedOrder")
    expect(billing_events).to include("PlacedOrder")
  end

  it "policies react to events from other domains" do
    pizza = PizzasDomain::Pizza.create(name: "Margherita")
    seed = PizzasDomain::Order.new(id: pizza.id, pizza: pizza.id, quantity: 1)
    seed.save

    # PlaceOrder in pizzas_domain fires PlacedOrder
    # BillOnOrder policy in billing_domain reacts and triggers CreateInvoice
    PizzasDomain::Order.place(pizza: pizza.id, quantity: 3)

    billing_events = @billing_app.events.map { |e| e.class.name.split("::").last }
    expect(billing_events).to include("CreatedInvoice")

    # Policy-triggered aggregate should also be persisted
    invoices = BillingDomain::Invoice.all
    expect(invoices.size).to eq(1)
    expect(invoices.first.quantity).to eq(3)
  end

  it "domains are isolated — can't access each other's aggregates" do
    expect(defined?(PizzasDomain::Invoice)).to be_nil
    expect(defined?(BillingDomain::Pizza)).to be_nil
  end
end

RSpec.describe "Cross-domain qualified references" do
  after { Hecks::Utils.cleanup_constants! }

  it "allows qualified reference_to across domains" do
    shipping = Hecks.domain "Shipping" do
      aggregate "Shipment" do
        attribute :address, String
        reference_to "Billing::Invoice"

        command "CreateShipment" do
          attribute :address, String
          reference_to "Billing::Invoice", validate: false
        end
      end
    end

    billing = Hecks.domain "Billing" do
      aggregate "Invoice" do
        attribute :total, Integer

        command "CreateInvoice" do
          attribute :total, Integer
        end
      end
    end

    shared_bus = Hecks::EventBus.new
    Hecks.load(billing, event_bus: shared_bus)
    Hecks.load(shipping, event_bus: shared_bus)

    # Qualified reference should resolve to the foreign domain's aggregate
    invoice = BillingDomain::Invoice.create(total: 100)
    shipment = ShippingDomain::Shipment.create(address: "123 Main", invoice: invoice.id)
    expect(shipment.address).to eq("123 Main")
  end

  it "rejects unqualified references that match a foreign aggregate" do
    shipping = Hecks.domain "Shipping" do
      aggregate "Shipment" do
        attribute :address, String
        reference_to "Invoice"

        command "CreateShipment" do
          attribute :address, String
        end
      end
    end

    billing = Hecks.domain "Billing" do
      aggregate "Invoice" do
        attribute :total, Integer

        command "CreateInvoice" do
          attribute :total, Integer
        end
      end
    end

    expect {
      Hecks::MultiDomain::Validator.validate_no_cross_domain_references([shipping, billing])
    }.to raise_error(Hecks::ValidationError, /Qualify the reference/)
  end

  it "rejects qualified references to unknown domains" do
    shipping = Hecks.domain "Shipping" do
      aggregate "Shipment" do
        attribute :address, String
        reference_to "Unknown::Widget"

        command "CreateShipment" do
          attribute :address, String
        end
      end
    end

    expect {
      Hecks::MultiDomain::Validator.validate_no_cross_domain_references([shipping])
    }.to raise_error(Hecks::ValidationError, /not loaded/)
  end

  it "resolves cross-domain reference for IDOR validation" do
    billing = Hecks.domain "Billing" do
      aggregate "Invoice" do
        attribute :total, Integer

        command "CreateInvoice" do
          attribute :total, Integer
        end
      end
    end

    shipping = Hecks.domain "Shipping" do
      aggregate "Shipment" do
        attribute :address, String
        reference_to "Billing::Invoice"

        command "CreateShipment" do
          attribute :address, String
          reference_to "Billing::Invoice"
        end
      end
    end

    shared_bus = Hecks::EventBus.new
    Hecks.load(billing, event_bus: shared_bus)
    Hecks.load(shipping, event_bus: shared_bus)

    # Create an invoice so the reference can resolve
    invoice = BillingDomain::Invoice.create(total: 50)

    # Should succeed — the cross-domain reference resolves to BillingDomain::Invoice
    result = ShippingDomain::Shipment.create(address: "456 Elm", invoice: invoice.id)
    expect(result.address).to eq("456 Elm")

    # Should fail — nonexistent invoice ID
    expect {
      ShippingDomain::Shipment.create(address: "789 Oak", invoice: "fake-id")
    }.to raise_error(Hecks::ReferenceNotFound)
  end
end
