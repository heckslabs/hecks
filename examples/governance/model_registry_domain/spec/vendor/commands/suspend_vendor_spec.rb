require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::Vendor::Commands::SuspendVendor do
  describe "attributes" do
    subject(:command) { described_class.new(vendor_id: "example") }

    it "has vendor_id" do
      expect(command.vendor_id).to eq("example")
    end

  end

  describe "event" do
    it "emits SuspendedVendor" do
      expect(described_class.event_name).to eq("SuspendedVendor")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits SuspendedVendor" do
      agg = Vendor.register(
          name: "example",
          contact_email: "example",
          risk_tier: "example"
        )
      Vendor.suspend(vendor_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("SuspendedVendor")
    end
  end
end
