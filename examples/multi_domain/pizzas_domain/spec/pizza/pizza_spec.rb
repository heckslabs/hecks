require_relative "../spec_helper"

RSpec.describe PizzasDomain::Pizza do
  describe "creating a Pizza" do
    subject(:pizza) { described_class.new(
          name: "example",
          style: "example",
          price: 1.0
        ) }

    it "assigns an id" do
      expect(pizza.id).not_to be_nil
    end

    it "sets name" do
      expect(pizza.name).to eq("example")
    end

    it "sets style" do
      expect(pizza.style).to eq("example")
    end

    it "sets price" do
      expect(pizza.price).to eq(1.0)
    end
  end

  describe "identity" do
    it "two Pizzas with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          name: "example",
          style: "example",
          price: 1.0,
          id: id
        )
      b = described_class.new(
          name: "example",
          style: "example",
          price: 1.0,
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Pizzas with different ids are not equal" do
      a = described_class.new(
          name: "example",
          style: "example",
          price: 1.0
        )
      b = described_class.new(
          name: "example",
          style: "example",
          price: 1.0
        )
      expect(a).not_to eq(b)
    end
  end
end
