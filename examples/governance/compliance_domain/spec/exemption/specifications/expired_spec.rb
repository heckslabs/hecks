require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::Exemption::Specifications::Expired do
  it "responds to satisfied_by?" do
    expect(described_class).to respond_to(:satisfied_by?)
  end

  it "returns a boolean for a sample object" do
    obj = OpenStruct.new(model_id: "example", policy_id: "ref-id-123", requirement: "example", reason: "example", approved_by_id: "example", approved_at: DateTime.now, expires_at: Date.today, scope: "example", status: "example")
    result = described_class.satisfied_by?(obj)
    expect([true, false]).to include(result)
  end
end
