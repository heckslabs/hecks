require_relative "../../spec_helper"

RSpec.describe ShippingDomain::Shipment::Commands::ShipShipment do
  describe "attributes" do
    subject(:command) { described_class.new(shipment: "example") }

    it "has shipment" do
      expect(command.shipment).to eq("example")
    end

  end

  describe "event" do
    it "emits ShippedShipment" do
      expect(described_class.event_name).to eq("ShippedShipment")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = Shipment.ship(shipment: "example")
      expect(result).not_to be_nil
      expect(Shipment.find(result.id)).not_to be_nil
    end

    it "emits ShippedShipment to the event log" do
      Shipment.ship(shipment: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("ShippedShipment")
    end
  end
end
