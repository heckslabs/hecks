require_relative "../spec_helper"

RSpec.describe RiskAssessmentDomain::Assessment::Finding do
  subject(:finding) { described_class.new(
          category: "example",
          severity: "example",
          description: "example",
          status: "example"
        ) }

  it "has a UUID id" do
    expect(finding.id).to match(/\A[0-9a-f-]{36}\z/)
  end

  it "is mutable (not frozen)" do
    expect(finding).not_to be_frozen
  end

  it "uses identity-based equality" do
    id = SecureRandom.uuid
    a = described_class.new(
          category: "example",
          severity: "example",
          description: "example",
          status: "example"
        , id: id)
    b = described_class.new(
          category: "example",
          severity: "example",
          description: "example",
          status: "example"
        , id: id)
    expect(a).to eq(b)
  end

  it "enforces: severity must be valid" do
    # TODO: construct a Finding that violates: severity must be valid
    # expect { described_class.new(...) }.to raise_error(RiskAssessmentDomain::InvariantError)
  end
end
