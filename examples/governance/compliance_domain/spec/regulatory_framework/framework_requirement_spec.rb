require_relative "../spec_helper"

RSpec.describe ComplianceDomain::RegulatoryFramework::FrameworkRequirement do
  subject(:framework_requirement) { described_class.new(
          article: "example",
          section: "example",
          description: "example",
          risk_category: "example"
        ) }

  it "is immutable" do
    expect(framework_requirement).to be_frozen
  end

  it "is equal when all attributes match" do
    other = described_class.new(
          article: "example",
          section: "example",
          description: "example",
          risk_category: "example"
        )
    expect(framework_requirement).to eq(other)
  end
end
