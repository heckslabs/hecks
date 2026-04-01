require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::DataUsageAgreement::Commands::RevokeAgreement do
  describe "attributes" do
    subject(:command) { described_class.new(agreement_id: "example") }

    it "has agreement_id" do
      expect(command.agreement_id).to eq("example")
    end

  end

  describe "event" do
    it "emits RevokedAgreement" do
      expect(described_class.event_name).to eq("RevokedAgreement")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits RevokedAgreement" do
      agg = DataUsageAgreement.create(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "example"
        )
      DataUsageAgreement.revoke(agreement_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RevokedAgreement")
    end
  end
end
