require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::TrainingRecord::Specifications::Expired do
  it "responds to satisfied_by?" do
    expect(described_class).to respond_to(:satisfied_by?)
  end

  it "returns a boolean for a sample object" do
    obj = OpenStruct.new(stakeholder_id: "example", policy_id: "ref-id-123", completed_at: DateTime.now, expires_at: Date.today, certification: "example", status: "example")
    result = described_class.satisfied_by?(obj)
    expect([true, false]).to include(result)
  end
end
