require_relative "../../spec_helper"

RSpec.describe RiskAssessmentDomain::Assessment::Commands::InitiateAssessment do
  describe "attributes" do
    subject(:command) { described_class.new(model_id: "example", assessor_id: "example") }

    it "has model_id" do
      expect(command.model_id).to eq("example")
    end

    it "has assessor_id" do
      expect(command.assessor_id).to eq("example")
    end

  end

  describe "event" do
    it "emits InitiatedAssessment" do
      expect(described_class.event_name).to eq("InitiatedAssessment")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = Assessment.initiate(model_id: "example", assessor_id: "example")
      expect(result).not_to be_nil
      expect(Assessment.find(result.id)).not_to be_nil
    end

    it "emits InitiatedAssessment to the event log" do
      Assessment.initiate(model_id: "example", assessor_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("InitiatedAssessment")
    end
  end
end
