require_relative "../../spec_helper"

RSpec.describe BillingDomain::Invoice::Commands::CreateInvoice do
  describe "attributes" do
    subject(:command) { described_class.new(pizza: "example", quantity: 1) }

    it "has pizza" do
      expect(command.pizza).to eq("example")
    end

    it "has quantity" do
      expect(command.quantity).to eq(1)
    end

  end

  describe "event" do
    it "emits CreatedInvoice" do
      expect(described_class.event_name).to eq("CreatedInvoice")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = Invoice.create(pizza: "example", quantity: 1)
      expect(result).not_to be_nil
      expect(Invoice.find(result.id)).not_to be_nil
    end

    it "emits CreatedInvoice to the event log" do
      Invoice.create(pizza: "example", quantity: 1)
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("CreatedInvoice")
    end
  end
end
