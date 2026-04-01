require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::TrainingRecord::Commands::RenewTraining do
  describe "attributes" do
    subject(:command) { described_class.new(
          training_record_id: "example",
          certification: "example",
          expires_at: Date.today
        ) }

    it "has training_record_id" do
      expect(command.training_record_id).to eq("example")
    end

    it "has certification" do
      expect(command.certification).to eq("example")
    end

    it "has expires_at" do
      expect(command.expires_at).to eq(Date.today)
    end

  end

  describe "event" do
    it "emits RenewedTraining" do
      expect(described_class.event_name).to eq("RenewedTraining")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits RenewedTraining" do
      agg = TrainingRecord.assign_training(stakeholder_id: "example", policy_id: "ref-id-123")
      TrainingRecord.renew_training(training_record_id: "example", certification: "example", expires_at: Date.today)
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RenewedTraining")
    end
  end
end
