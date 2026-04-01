require_relative "../../spec_helper"

RSpec.describe OperationsDomain::Incident::Commands::InvestigateIncident do
  describe "attributes" do
    subject(:command) { described_class.new(incident_id: "example") }

    it "has incident_id" do
      expect(command.incident_id).to eq("example")
    end

  end

  describe "event" do
    it "emits InvestigatedIncident" do
      expect(described_class.event_name).to eq("InvestigatedIncident")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits InvestigatedIncident" do
      agg = Incident.report(
          model_id: "example",
          severity: "example",
          category: "example",
          description: "example",
          reported_by_id: "example"
        )
      Incident.investigate(incident_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("InvestigatedIncident")
    end
  end
end
