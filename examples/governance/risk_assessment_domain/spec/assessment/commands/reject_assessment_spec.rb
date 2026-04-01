require_relative "../../spec_helper"

RSpec.describe RiskAssessmentDomain::Assessment::Commands::RejectAssessment do
  describe "attributes" do
    subject(:command) { described_class.new(assessment_id: "example") }

    it "has assessment_id" do
      expect(command.assessment_id).to eq("example")
    end

  end

  describe "event" do
    it "emits RejectedAssessment" do
      expect(described_class.event_name).to eq("RejectedAssessment")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits RejectedAssessment" do
      agg = Assessment.initiate(model_id: "example", assessor_id: "example")
      Assessment.reject(assessment_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RejectedAssessment")
    end
  end
end
