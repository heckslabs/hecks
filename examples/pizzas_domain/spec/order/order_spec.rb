require_relative "../spec_helper"

RSpec.describe PizzasDomain::Order do
  describe "creating a Order" do
    subject(:order) { described_class.new(
          customer_name: "example",
          items: [],
          status: "example"
        ) }

    it "assigns an id" do
      expect(order.id).not_to be_nil
    end

    it "sets customer_name" do
      expect(order.customer_name).to eq("example")
    end

    it "sets items" do
      expect(order.items).to eq([])
    end

    it "sets status" do
      expect(order.status).to eq("example")
    end
  end

  describe "customer_name validation" do
    it "rejects nil customer_name" do
      expect {
        described_class.new(
          customer_name: nil,
          items: [],
          status: "example"
        )
      }.to raise_error(PizzasDomain::ValidationError, /customer_name/)
    end
  end

  describe "identity" do
    it "two Orders with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          customer_name: "example",
          items: [],
          status: "example",
          id: id
        )
      b = described_class.new(
          customer_name: "example",
          items: [],
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Orders with different ids are not equal" do
      a = described_class.new(
          customer_name: "example",
          items: [],
          status: "example"
        )
      b = described_class.new(
          customer_name: "example",
          items: [],
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
