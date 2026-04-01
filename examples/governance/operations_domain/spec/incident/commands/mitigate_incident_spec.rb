require_relative "../../spec_helper"

RSpec.describe OperationsDomain::Incident::Commands::MitigateIncident do
  describe "attributes" do
    subject(:command) { described_class.new(incident_id: "example") }

    it "has incident_id" do
      expect(command.incident_id).to eq("example")
    end

  end

  describe "event" do
    it "emits MitigatedIncident" do
      expect(described_class.event_name).to eq("MitigatedIncident")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits MitigatedIncident" do
      agg = Incident.report(
          model_id: "example",
          severity: "example",
          category: "example",
          description: "example",
          reported_by_id: "example"
        )
      Incident.mitigate(incident_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("MitigatedIncident")
    end
  end
end
