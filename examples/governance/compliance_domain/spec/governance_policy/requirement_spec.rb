require_relative "../spec_helper"

RSpec.describe ComplianceDomain::GovernancePolicy::Requirement do
  subject(:requirement) { described_class.new(
          description: "example",
          priority: "low",
          category: "example"
        ) }

  it "is immutable" do
    expect(requirement).to be_frozen
  end

  it "is equal when all attributes match" do
    other = described_class.new(
          description: "example",
          priority: "low",
          category: "example"
        )
    expect(requirement).to eq(other)
  end
end
