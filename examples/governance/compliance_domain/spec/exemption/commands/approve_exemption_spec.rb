require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::Exemption::Commands::ApproveExemption do
  describe "attributes" do
    subject(:command) { described_class.new(
          exemption_id: "example",
          approved_by_id: "example",
          expires_at: Date.today
        ) }

    it "has exemption_id" do
      expect(command.exemption_id).to eq("example")
    end

    it "has approved_by_id" do
      expect(command.approved_by_id).to eq("example")
    end

    it "has expires_at" do
      expect(command.expires_at).to eq(Date.today)
    end

  end

  describe "event" do
    it "emits ApprovedExemption" do
      expect(described_class.event_name).to eq("ApprovedExemption")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits ApprovedExemption" do
      agg = Exemption.request(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example"
        )
      Exemption.approve(exemption_id: "example", approved_by_id: "example", expires_at: Date.today)
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("ApprovedExemption")
    end
  end
end
