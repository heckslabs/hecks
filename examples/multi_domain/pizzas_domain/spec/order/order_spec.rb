require_relative "../spec_helper"

RSpec.describe PizzasDomain::Order do
  describe "creating a Order" do
    subject(:order) { described_class.new(quantity: 1) }

    it "assigns an id" do
      expect(order.id).not_to be_nil
    end

    it "sets quantity" do
      expect(order.quantity).to eq(1)
    end
  end

  describe "identity" do
    it "two Orders with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(quantity: 1, id: id)
      b = described_class.new(quantity: 1, id: id)
      expect(a).to eq(b)
    end

    it "two Orders with different ids are not equal" do
      a = described_class.new(quantity: 1)
      b = described_class.new(quantity: 1)
      expect(a).not_to eq(b)
    end
  end
end
