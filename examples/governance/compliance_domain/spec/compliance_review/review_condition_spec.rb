require_relative "../spec_helper"

RSpec.describe ComplianceDomain::ComplianceReview::ReviewCondition do
  subject(:review_condition) { described_class.new(
          requirement: "example",
          met: "yes",
          evidence: "example"
        ) }

  it "is immutable" do
    expect(review_condition).to be_frozen
  end

  it "is equal when all attributes match" do
    other = described_class.new(
          requirement: "example",
          met: "yes",
          evidence: "example"
        )
    expect(review_condition).to eq(other)
  end
end
