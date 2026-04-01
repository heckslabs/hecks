require_relative "../../spec_helper"

RSpec.describe RiskAssessmentDomain::Assessment::Commands::RecordFinding do
  describe "attributes" do
    subject(:command) { described_class.new(
          assessment_id: "example",
          category: "example",
          severity: "example",
          description: "example"
        ) }

    it "has assessment_id" do
      expect(command.assessment_id).to eq("example")
    end

    it "has category" do
      expect(command.category).to eq("example")
    end

    it "has severity" do
      expect(command.severity).to eq("example")
    end

    it "has description" do
      expect(command.description).to eq("example")
    end

  end

  describe "event" do
    it "emits RecordedFinding" do
      expect(described_class.event_name).to eq("RecordedFinding")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits RecordedFinding" do
      agg = Assessment.initiate(model_id: "example", assessor_id: "example")
      Assessment.record_finding(assessment_id: "example", category: "example", severity: "example", description: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RecordedFinding")
    end
  end
end
