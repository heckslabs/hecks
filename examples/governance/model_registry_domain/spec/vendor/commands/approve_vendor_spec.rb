require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::Vendor::Commands::ApproveVendor do
  describe "attributes" do
    subject(:command) { described_class.new(
          vendor_id: "example",
          assessment_date: Date.today,
          next_review_date: Date.today
        ) }

    it "has vendor_id" do
      expect(command.vendor_id).to eq("example")
    end

    it "has assessment_date" do
      expect(command.assessment_date).to eq(Date.today)
    end

    it "has next_review_date" do
      expect(command.next_review_date).to eq(Date.today)
    end

  end

  describe "event" do
    it "emits ApprovedVendor" do
      expect(described_class.event_name).to eq("ApprovedVendor")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits ApprovedVendor" do
      agg = Vendor.register(
          name: "example",
          contact_email: "example",
          risk_tier: "example"
        )
      Vendor.approve(vendor_id: "example", assessment_date: Date.today, next_review_date: Date.today)
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("ApprovedVendor")
    end
  end
end
