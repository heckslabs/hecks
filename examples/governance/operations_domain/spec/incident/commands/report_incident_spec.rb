require_relative "../../spec_helper"

RSpec.describe OperationsDomain::Incident::Commands::ReportIncident do
  describe "attributes" do
    subject(:command) { described_class.new(
          model_id: "example",
          severity: "example",
          category: "example",
          description: "example",
          reported_by_id: "example"
        ) }

    it "has model_id" do
      expect(command.model_id).to eq("example")
    end

    it "has severity" do
      expect(command.severity).to eq("example")
    end

    it "has category" do
      expect(command.category).to eq("example")
    end

    it "has description" do
      expect(command.description).to eq("example")
    end

    it "has reported_by_id" do
      expect(command.reported_by_id).to eq("example")
    end

  end

  describe "event" do
    it "emits ReportedIncident" do
      expect(described_class.event_name).to eq("ReportedIncident")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = Incident.report(
          model_id: "example",
          severity: "example",
          category: "example",
          description: "example",
          reported_by_id: "example"
        )
      expect(result).not_to be_nil
      expect(Incident.find(result.id)).not_to be_nil
    end

    it "emits ReportedIncident to the event log" do
      Incident.report(
          model_id: "example",
          severity: "example",
          category: "example",
          description: "example",
          reported_by_id: "example"
        )
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("ReportedIncident")
    end
  end
end
