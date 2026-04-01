require_relative "../spec_helper"

RSpec.describe "Vendor lifecycle" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts in 'pending_review' state" do
    agg = Vendor.register(
          name: "example",
          contact_email: "example",
          risk_tier: "example"
        )
    expect(agg.status).to eq("pending_review")
  end

  it "RegisterVendor transitions to 'pending_review'" do
    agg = Vendor.register(
          name: "example",
          contact_email: "example",
          risk_tier: "example"
        )
    Vendor.register(name: "example", contact_email: "example", risk_tier: "example")
    updated = Vendor.find(agg.id)
    expect(updated.status).to eq("pending_review")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RegisteredVendor")
  end

  it "ApproveVendor transitions to 'approved'" do
    agg = Vendor.register(
          name: "example",
          contact_email: "example",
          risk_tier: "example"
        )
    Vendor.register(name: "example", contact_email: "example", risk_tier: "example")
    Vendor.approve(vendor_id: agg.id, assessment_date: Date.today, next_review_date: Date.today)
    updated = Vendor.find(agg.id)
    expect(updated.status).to eq("approved")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("ApprovedVendor")
  end

  it "SuspendVendor transitions to 'suspended'" do
    agg = Vendor.register(
          name: "example",
          contact_email: "example",
          risk_tier: "example"
        )
    Vendor.register(name: "example", contact_email: "example", risk_tier: "example")
    Vendor.approve(vendor_id: agg.id, assessment_date: Date.today, next_review_date: Date.today)
    Vendor.suspend(vendor_id: agg.id)
    updated = Vendor.find(agg.id)
    expect(updated.status).to eq("suspended")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("SuspendedVendor")
  end

  it "generates status predicates" do
    agg = Vendor.register(
          name: "example",
          contact_email: "example",
          risk_tier: "example"
        )
    expect(agg.pending_review?).to be true
    expect(agg.approved?).to be false
    expect(agg.suspended?).to be false
  end
end
