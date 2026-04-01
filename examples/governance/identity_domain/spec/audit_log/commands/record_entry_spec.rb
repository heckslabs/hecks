require_relative "../../spec_helper"

RSpec.describe IdentityDomain::AuditLog::Commands::RecordEntry do
  describe "attributes" do
    subject(:command) { described_class.new(
          entity_type: "example",
          entity_id: "example",
          action: "example",
          actor_id: "ref-id-123",
          details: "example"
        ) }

    it "has entity_type" do
      expect(command.entity_type).to eq("example")
    end

    it "has entity_id" do
      expect(command.entity_id).to eq("example")
    end

    it "has action" do
      expect(command.action).to eq("example")
    end

    it "has actor_id" do
      expect(command.actor_id).to eq("ref-id-123")
    end

    it "has details" do
      expect(command.details).to eq("example")
    end

  end

  describe "event" do
    it "emits RecordedEntry" do
      expect(described_class.event_name).to eq("RecordedEntry")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = AuditLog.record_entry(
          entity_type: "example",
          entity_id: "example",
          action: "example",
          actor_id: "ref-id-123",
          details: "example"
        )
      expect(result).not_to be_nil
      expect(AuditLog.find(result.id)).not_to be_nil
    end

    it "emits RecordedEntry to the event log" do
      AuditLog.record_entry(
          entity_type: "example",
          entity_id: "example",
          action: "example",
          actor_id: "ref-id-123",
          details: "example"
        )
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RecordedEntry")
    end
  end
end
