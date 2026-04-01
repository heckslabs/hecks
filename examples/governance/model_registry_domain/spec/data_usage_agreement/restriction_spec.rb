require_relative "../spec_helper"

RSpec.describe ModelRegistryDomain::DataUsageAgreement::Restriction do
  subject(:restriction) { described_class.new(type: "example", description: "example") }

  it "is immutable" do
    expect(restriction).to be_frozen
  end

  it "is equal when all attributes match" do
    other = described_class.new(type: "example", description: "example")
    expect(restriction).to eq(other)
  end
end
