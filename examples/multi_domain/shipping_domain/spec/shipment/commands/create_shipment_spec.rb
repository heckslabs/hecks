require_relative "../../spec_helper"

RSpec.describe ShippingDomain::Shipment::Commands::CreateShipment do
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
    it "emits CreatedShipment" do
      expect(described_class.event_name).to eq("CreatedShipment")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = Shipment.create(pizza: "example", quantity: 1)
      expect(result).not_to be_nil
      expect(Shipment.find(result.id)).not_to be_nil
    end

    it "emits CreatedShipment to the event log" do
      Shipment.create(pizza: "example", quantity: 1)
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("CreatedShipment")
    end
  end
end
