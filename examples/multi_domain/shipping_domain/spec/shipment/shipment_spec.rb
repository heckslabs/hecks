require_relative "../spec_helper"

RSpec.describe ShippingDomain::Shipment do
  describe "creating a Shipment" do
    subject(:shipment) { described_class.new(
          pizza: "example",
          quantity: 1,
          status: "example"
        ) }

    it "assigns an id" do
      expect(shipment.id).not_to be_nil
    end

    it "sets pizza" do
      expect(shipment.pizza).to eq("example")
    end

    it "sets quantity" do
      expect(shipment.quantity).to eq(1)
    end

    it "sets status" do
      expect(shipment.status).to eq("example")
    end
  end

  describe "identity" do
    it "two Shipments with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          pizza: "example",
          quantity: 1,
          status: "example",
          id: id
        )
      b = described_class.new(
          pizza: "example",
          quantity: 1,
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Shipments with different ids are not equal" do
      a = described_class.new(
          pizza: "example",
          quantity: 1,
          status: "example"
        )
      b = described_class.new(
          pizza: "example",
          quantity: 1,
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
