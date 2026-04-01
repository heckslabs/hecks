require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::Vendor::Events::SuspendedVendor do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          vendor_id: "example",
          name: "example",
          contact_email: "example",
          risk_tier: "low",
          assessment_date: Date.today,
          next_review_date: Date.today,
          sla_terms: "example",
          status: "example"
        ) }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries aggregate_id" do
    expect(event.aggregate_id).to eq("example")
  end

  it "carries vendor_id" do
    expect(event.vendor_id).to eq("example")
  end

  it "carries name" do
    expect(event.name).to eq("example")
  end

  it "carries contact_email" do
    expect(event.contact_email).to eq("example")
  end

  it "carries risk_tier" do
    expect(event.risk_tier).to eq("low")
  end

  it "carries assessment_date" do
    expect(event.assessment_date).not_to be_nil
  end

  it "carries next_review_date" do
    expect(event.next_review_date).not_to be_nil
  end

  it "carries sla_terms" do
    expect(event.sla_terms).to eq("example")
  end

  it "carries status" do
    expect(event.status).to eq("example")
  end
end
