require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::Vendor::Commands::RegisterVendor do
  describe "attributes" do
    subject(:command) { described_class.new(
          name: "example",
          contact_email: "example",
          risk_tier: "example"
        ) }

    it "has name" do
      expect(command.name).to eq("example")
    end

    it "has contact_email" do
      expect(command.contact_email).to eq("example")
    end

    it "has risk_tier" do
      expect(command.risk_tier).to eq("example")
    end

  end

  describe "event" do
    it "emits RegisteredVendor" do
      expect(described_class.event_name).to eq("RegisteredVendor")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = Vendor.register(
          name: "example",
          contact_email: "example",
          risk_tier: "example"
        )
      expect(result).not_to be_nil
      expect(Vendor.find(result.id)).not_to be_nil
    end

    it "emits RegisteredVendor to the event log" do
      Vendor.register(
          name: "example",
          contact_email: "example",
          risk_tier: "example"
        )
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RegisteredVendor")
    end
  end
end
