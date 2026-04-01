require_relative "../../spec_helper"

RSpec.describe RiskAssessmentDomain::Assessment::Commands::SubmitAssessment do
  describe "attributes" do
    subject(:command) { described_class.new(
          assessment_id: "example",
          risk_level: "example",
          bias_score: 1.0,
          safety_score: 1.0,
          transparency_score: 1.0,
          overall_score: 1.0
        ) }

    it "has assessment_id" do
      expect(command.assessment_id).to eq("example")
    end

    it "has risk_level" do
      expect(command.risk_level).to eq("example")
    end

    it "has bias_score" do
      expect(command.bias_score).to eq(1.0)
    end

    it "has safety_score" do
      expect(command.safety_score).to eq(1.0)
    end

    it "has transparency_score" do
      expect(command.transparency_score).to eq(1.0)
    end

    it "has overall_score" do
      expect(command.overall_score).to eq(1.0)
    end

  end

  describe "event" do
    it "emits SubmittedAssessment" do
      expect(described_class.event_name).to eq("SubmittedAssessment")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits SubmittedAssessment" do
      agg = Assessment.initiate(model_id: "example", assessor_id: "example")
      Assessment.submit(assessment_id: "example", risk_level: "example", bias_score: 1.0, safety_score: 1.0, transparency_score: 1.0, overall_score: 1.0)
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("SubmittedAssessment")
    end
  end
end
