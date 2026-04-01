require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::DataUsageAgreement::Commands::RenewAgreement do
  describe "attributes" do
    subject(:command) { described_class.new(agreement_id: "example", expiration_date: Date.today) }

    it "has agreement_id" do
      expect(command.agreement_id).to eq("example")
    end

    it "has expiration_date" do
      expect(command.expiration_date).to eq(Date.today)
    end

  end

  describe "event" do
    it "emits RenewedAgreement" do
      expect(described_class.event_name).to eq("RenewedAgreement")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits RenewedAgreement" do
      agg = DataUsageAgreement.create(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "example"
        )
      DataUsageAgreement.renew(agreement_id: "example", expiration_date: Date.today)
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RenewedAgreement")
    end
  end
end
