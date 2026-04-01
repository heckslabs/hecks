require_relative "../spec_helper"

RSpec.describe PizzasDomain::Order::OrderItem do
  subject(:order_item) { described_class.new(pizza: "example", quantity: 1) }

  it "is immutable" do
    expect(order_item).to be_frozen
  end

  it "is equal when all attributes match" do
    other = described_class.new(pizza: "example", quantity: 1)
    expect(order_item).to eq(other)
  end

  it "enforces: quantity must be positive" do
    # TODO: construct a OrderItem that violates: quantity must be positive
    # expect { described_class.new(...) }.to raise_error(PizzasDomain::InvariantError)
  end
end
