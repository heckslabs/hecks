require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::DataUsageAgreement::Commands::ActivateAgreement do
  describe "attributes" do
    subject(:command) { described_class.new(
          agreement_id: "example",
          effective_date: Date.today,
          expiration_date: Date.today
        ) }

    it "has agreement_id" do
      expect(command.agreement_id).to eq("example")
    end

    it "has effective_date" do
      expect(command.effective_date).to eq(Date.today)
    end

    it "has expiration_date" do
      expect(command.expiration_date).to eq(Date.today)
    end

  end

  describe "event" do
    it "emits ActivatedAgreement" do
      expect(described_class.event_name).to eq("ActivatedAgreement")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits ActivatedAgreement" do
      agg = DataUsageAgreement.create(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "example"
        )
      DataUsageAgreement.activate(agreement_id: "example", effective_date: Date.today, expiration_date: Date.today)
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("ActivatedAgreement")
    end
  end
end
