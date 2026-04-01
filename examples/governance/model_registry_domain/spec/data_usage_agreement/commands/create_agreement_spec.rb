require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::DataUsageAgreement::Commands::CreateAgreement do
  describe "attributes" do
    subject(:command) { described_class.new(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "example"
        ) }

    it "has model_id" do
      expect(command.model_id).to eq("ref-id-123")
    end

    it "has data_source" do
      expect(command.data_source).to eq("example")
    end

    it "has purpose" do
      expect(command.purpose).to eq("example")
    end

    it "has consent_type" do
      expect(command.consent_type).to eq("example")
    end

  end

  describe "event" do
    it "emits CreatedAgreement" do
      expect(described_class.event_name).to eq("CreatedAgreement")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = DataUsageAgreement.create(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "example"
        )
      expect(result).not_to be_nil
      expect(DataUsageAgreement.find(result.id)).not_to be_nil
    end

    it "emits CreatedAgreement to the event log" do
      DataUsageAgreement.create(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "example"
        )
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("CreatedAgreement")
    end
  end
end
