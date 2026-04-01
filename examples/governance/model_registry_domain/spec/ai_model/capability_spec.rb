require_relative "../spec_helper"

RSpec.describe ModelRegistryDomain::AiModel::Capability do
  subject(:capability) { described_class.new(name: "example", category: "example") }

  it "is immutable" do
    expect(capability).to be_frozen
  end

  it "is equal when all attributes match" do
    other = described_class.new(name: "example", category: "example")
    expect(capability).to eq(other)
  end
end
