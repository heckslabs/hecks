require_relative "../spec_helper"

RSpec.describe RiskAssessmentDomain::Assessment::Mitigation do
  subject(:mitigation) { described_class.new(
          finding_category: "example",
          action: "example",
          status: "example"
        ) }

  it "has a UUID id" do
    expect(mitigation.id).to match(/\A[0-9a-f-]{36}\z/)
  end

  it "is mutable (not frozen)" do
    expect(mitigation).not_to be_frozen
  end

  it "uses identity-based equality" do
    id = SecureRandom.uuid
    a = described_class.new(
          finding_category: "example",
          action: "example",
          status: "example"
        , id: id)
    b = described_class.new(
          finding_category: "example",
          action: "example",
          status: "example"
        , id: id)
    expect(a).to eq(b)
  end
end
