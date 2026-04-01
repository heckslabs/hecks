require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::Exemption::Commands::RevokeExemption do
  describe "attributes" do
    subject(:command) { described_class.new(exemption_id: "example") }

    it "has exemption_id" do
      expect(command.exemption_id).to eq("example")
    end

  end

  describe "event" do
    it "emits RevokedExemption" do
      expect(described_class.event_name).to eq("RevokedExemption")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits RevokedExemption" do
      agg = Exemption.request(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example"
        )
      Exemption.revoke(exemption_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RevokedExemption")
    end
  end
end
