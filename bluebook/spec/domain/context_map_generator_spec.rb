require "spec_helper"

RSpec.describe Hecks::ContextMapGenerator do
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

  let(:shipping_domain) do
    Hecks.domain "Shipping" do
      aggregate "Shipment" do
        attribute :pizza, String
        attribute :quantity, Integer
        command "CreateShipment" do
          attribute :pizza, String
          attribute :quantity, Integer
        end
        policy "ShipOnOrder" do
          on "PlacedOrder"
          trigger "CreateShipment"
        end
      end
    end
  end

  let(:domains) { [pizzas_domain, billing_domain, shipping_domain] }
  subject(:generator) { described_class.new(domains) }

  describe "#generate" do
    let(:mermaid) { generator.generate }

    it "produces a Mermaid graph TD diagram" do
      expect(mermaid).to start_with("graph TD")
    end

    it "includes a subgraph for each domain" do
      expect(mermaid).to include("subgraph Pizzas[Pizzas]")
      expect(mermaid).to include("subgraph Billing[Billing]")
      expect(mermaid).to include("subgraph Shipping[Shipping]")
    end

    it "includes aggregate nodes inside subgraphs" do
      expect(mermaid).to include("Pizzas_Pizza[Pizza]")
      expect(mermaid).to include("Pizzas_Order[Order]")
      expect(mermaid).to include("Billing_Invoice[Invoice]")
    end

    it "draws cross-domain event arrows" do
      expect(mermaid).to include("Pizzas -->|PlacedOrder| Billing")
      expect(mermaid).to include("Pizzas -->|PlacedOrder| Shipping")
    end
  end

  describe "#generate_text" do
    let(:text) { generator.generate_text }

    it "lists bounded contexts" do
      expect(text).to include("[Pizzas] Aggregates: Pizza, Order")
      expect(text).to include("[Billing] Aggregates: Invoice")
    end

    it "lists cross-domain relationships" do
      expect(text).to include("Pizzas --> Billing")
      expect(text).to include("Pizzas --> Shipping")
    end

    it "shows event and policy names" do
      expect(text).to include("Event: PlacedOrder | Policy: BillOnOrder")
      expect(text).to include("Event: PlacedOrder | Policy: ShipOnOrder")
    end
  end

  describe "#relationships" do
    it "finds cross-domain event flows" do
      rels = generator.relationships
      expect(rels.size).to eq(2)
      expect(rels.map { |r| r[:downstream] }).to contain_exactly("Billing", "Shipping")
      expect(rels.all? { |r| r[:upstream] == "Pizzas" }).to be true
    end

    it "excludes intra-domain policies" do
      rels = generator.relationships
      expect(rels.none? { |r| r[:upstream] == r[:downstream] }).to be true
    end
  end

  describe "single domain" do
    subject(:generator) { described_class.new([pizzas_domain]) }

    it "generates a diagram with no relationship arrows" do
      mermaid = generator.generate
      expect(mermaid).to include("subgraph Pizzas")
      expect(mermaid).not_to include("-->|")
    end

    it "generates text with no relationships" do
      text = generator.generate_text
      expect(text).to include("[Pizzas]")
      expect(text).to include("Relationships:")
    end
  end
end
