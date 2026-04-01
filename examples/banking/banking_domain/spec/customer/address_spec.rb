require_relative "../spec_helper"

RSpec.describe BankingDomain::Customer::Address do
  subject(:address) { described_class.new(
          street: "example",
          city: "example",
          state: "example",
          zip: "example"
        ) }

  it "is immutable" do
    expect(address).to be_frozen
  end

  it "is equal when all attributes match" do
    other = described_class.new(
          street: "example",
          city: "example",
          state: "example",
          zip: "example"
        )
    expect(address).to eq(other)
  end
end
