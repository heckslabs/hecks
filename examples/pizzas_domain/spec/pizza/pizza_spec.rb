require_relative "../spec_helper"

RSpec.describe PizzasDomain::Pizza do
  describe "creating a Pizza" do
    subject(:pizza) { described_class.new(
          name: "example",
          description: "example",
          toppings: []
        ) }

    it "assigns an id" do
      expect(pizza.id).not_to be_nil
    end

    it "sets name" do
      expect(pizza.name).to eq("example")
    end

    it "sets description" do
      expect(pizza.description).to eq("example")
    end

    it "sets toppings" do
      expect(pizza.toppings).to eq([])
    end
  end

  describe "name validation" do
    it "rejects nil name" do
      expect {
        described_class.new(
          name: nil,
          description: "example",
          toppings: []
        )
      }.to raise_error(PizzasDomain::ValidationError, /name/)
    end
  end

  describe "description validation" do
    it "rejects nil description" do
      expect {
        described_class.new(
          name: "example",
          description: nil,
          toppings: []
        )
      }.to raise_error(PizzasDomain::ValidationError, /description/)
    end
  end

  describe "identity" do
    it "two Pizzas with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          name: "example",
          description: "example",
          toppings: [],
          id: id
        )
      b = described_class.new(
          name: "example",
          description: "example",
          toppings: [],
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Pizzas with different ids are not equal" do
      a = described_class.new(
          name: "example",
          description: "example",
          toppings: []
        )
      b = described_class.new(
          name: "example",
          description: "example",
          toppings: []
        )
      expect(a).not_to eq(b)
    end
  end
end
