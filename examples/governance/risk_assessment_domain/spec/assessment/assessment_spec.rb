require_relative "../spec_helper"

RSpec.describe RiskAssessmentDomain::Assessment do
  describe "creating a Assessment" do
    subject(:assessment) { described_class.new(
          model_id: "example",
          assessor_id: "example",
          risk_level: "low",
          bias_score: 1.0,
          safety_score: 1.0,
          transparency_score: 1.0,
          overall_score: 1.0,
          submitted_at: DateTime.now,
          findings: [],
          mitigations: [],
          status: "example"
        ) }

    it "assigns an id" do
      expect(assessment.id).not_to be_nil
    end

    it "sets model_id" do
      expect(assessment.model_id).to eq("example")
    end

    it "sets assessor_id" do
      expect(assessment.assessor_id).to eq("example")
    end

    it "sets risk_level" do
      expect(assessment.risk_level).to eq("low")
    end

    it "sets bias_score" do
      expect(assessment.bias_score).to eq(1.0)
    end

    it "sets safety_score" do
      expect(assessment.safety_score).to eq(1.0)
    end

    it "sets transparency_score" do
      expect(assessment.transparency_score).to eq(1.0)
    end

    it "sets overall_score" do
      expect(assessment.overall_score).to eq(1.0)
    end

    it "sets submitted_at" do
      expect(assessment.submitted_at).not_to be_nil
    end

    it "sets findings" do
      expect(assessment.findings).to eq([])
    end

    it "sets mitigations" do
      expect(assessment.mitigations).to eq([])
    end

    it "sets status" do
      expect(assessment.status).to eq("example")
    end
  end

  describe "model_id validation" do
    it "rejects nil model_id" do
      expect {
        described_class.new(
          model_id: nil,
          assessor_id: "example",
          risk_level: "low",
          bias_score: 1.0,
          safety_score: 1.0,
          transparency_score: 1.0,
          overall_score: 1.0,
          submitted_at: DateTime.now,
          findings: [],
          mitigations: [],
          status: "example"
        )
      }.to raise_error(RiskAssessmentDomain::ValidationError, /model_id/)
    end
  end

  describe "assessor_id validation" do
    it "rejects nil assessor_id" do
      expect {
        described_class.new(
          model_id: "example",
          assessor_id: nil,
          risk_level: "low",
          bias_score: 1.0,
          safety_score: 1.0,
          transparency_score: 1.0,
          overall_score: 1.0,
          submitted_at: DateTime.now,
          findings: [],
          mitigations: [],
          status: "example"
        )
      }.to raise_error(RiskAssessmentDomain::ValidationError, /assessor_id/)
    end
  end

  describe "invariant: scores must be between 0 and 1" do
    it "raises InvariantError when violated" do
      # TODO: construct an instance that violates: scores must be between 0 and 1
      # expect { described_class.new(...) }.to raise_error(RiskAssessmentDomain::InvariantError)
    end
  end

  describe "identity" do
    it "two Assessments with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          model_id: "example",
          assessor_id: "example",
          risk_level: "low",
          bias_score: 1.0,
          safety_score: 1.0,
          transparency_score: 1.0,
          overall_score: 1.0,
          submitted_at: DateTime.now,
          findings: [],
          mitigations: [],
          status: "example",
          id: id
        )
      b = described_class.new(
          model_id: "example",
          assessor_id: "example",
          risk_level: "low",
          bias_score: 1.0,
          safety_score: 1.0,
          transparency_score: 1.0,
          overall_score: 1.0,
          submitted_at: DateTime.now,
          findings: [],
          mitigations: [],
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Assessments with different ids are not equal" do
      a = described_class.new(
          model_id: "example",
          assessor_id: "example",
          risk_level: "low",
          bias_score: 1.0,
          safety_score: 1.0,
          transparency_score: 1.0,
          overall_score: 1.0,
          submitted_at: DateTime.now,
          findings: [],
          mitigations: [],
          status: "example"
        )
      b = described_class.new(
          model_id: "example",
          assessor_id: "example",
          risk_level: "low",
          bias_score: 1.0,
          safety_score: 1.0,
          transparency_score: 1.0,
          overall_score: 1.0,
          submitted_at: DateTime.now,
          findings: [],
          mitigations: [],
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
