require_relative "../../spec_helper"

RSpec.describe RiskAssessmentDomain::Assessment::Specifications::CriticalFindings do
  it "responds to satisfied_by?" do
    expect(described_class).to respond_to(:satisfied_by?)
  end

  it "returns a boolean for a sample object" do
    obj = OpenStruct.new(model_id: "example", assessor_id: "example", risk_level: "low", bias_score: 1.0, safety_score: 1.0, transparency_score: 1.0, overall_score: 1.0, submitted_at: DateTime.now, findings: [], mitigations: [], status: "example")
    result = described_class.satisfied_by?(obj)
    expect([true, false]).to include(result)
  end
end
