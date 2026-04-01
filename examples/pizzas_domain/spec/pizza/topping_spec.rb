require_relative "../spec_helper"

RSpec.describe PizzasDomain::Pizza::Topping do
  subject(:topping) { described_class.new(name: "example", amount: 1) }

  it "is immutable" do
    expect(topping).to be_frozen
  end

  it "is equal when all attributes match" do
    other = described_class.new(name: "example", amount: 1)
    expect(topping).to eq(other)
  end

  it "enforces: amount must be positive" do
    # TODO: construct a Topping that violates: amount must be positive
    # expect { described_class.new(...) }.to raise_error(PizzasDomain::InvariantError)
  end
end
