require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::TrainingRecord::Commands::AssignTraining do
  describe "attributes" do
    subject(:command) { described_class.new(stakeholder_id: "example", policy_id: "ref-id-123") }

    it "has stakeholder_id" do
      expect(command.stakeholder_id).to eq("example")
    end

    it "has policy_id" do
      expect(command.policy_id).to eq("ref-id-123")
    end

  end

  describe "event" do
    it "emits AssignedTraining" do
      expect(described_class.event_name).to eq("AssignedTraining")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = TrainingRecord.assign_training(stakeholder_id: "example", policy_id: "ref-id-123")
      expect(result).not_to be_nil
      expect(TrainingRecord.find(result.id)).not_to be_nil
    end

    it "emits AssignedTraining to the event log" do
      TrainingRecord.assign_training(stakeholder_id: "example", policy_id: "ref-id-123")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("AssignedTraining")
    end
  end
end
