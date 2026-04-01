require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::ComplianceReview::Commands::OpenReview do
  describe "attributes" do
    subject(:command) { described_class.new(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example"
        ) }

    it "has model_id" do
      expect(command.model_id).to eq("example")
    end

    it "has policy_id" do
      expect(command.policy_id).to eq("ref-id-123")
    end

    it "has reviewer_id" do
      expect(command.reviewer_id).to eq("example")
    end

  end

  describe "event" do
    it "emits OpenedReview" do
      expect(described_class.event_name).to eq("OpenedReview")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = ComplianceReview.open(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example"
        )
      expect(result).not_to be_nil
      expect(ComplianceReview.find(result.id)).not_to be_nil
    end

    it "emits OpenedReview to the event log" do
      ComplianceReview.open(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example"
        )
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("OpenedReview")
    end
  end
end
