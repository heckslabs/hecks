require_relative "../spec_helper"

RSpec.describe ModelRegistryDomain::AiModel::IntendedUse do
  subject(:intended_use) { described_class.new(description: "example", domain: "example") }

  it "is immutable" do
    expect(intended_use).to be_frozen
  end

  it "is equal when all attributes match" do
    other = described_class.new(description: "example", domain: "example")
    expect(intended_use).to eq(other)
  end
end
