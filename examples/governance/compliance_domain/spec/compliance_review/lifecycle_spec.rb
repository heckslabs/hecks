require_relative "../spec_helper"

RSpec.describe "ComplianceReview lifecycle" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts in 'open' state" do
    agg = ComplianceReview.open(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example"
        )
    expect(agg.status).to eq("open")
  end

  it "OpenReview transitions to 'open'" do
    agg = ComplianceReview.open(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example"
        )
    ComplianceReview.open(model_id: "example", policy_id: "ref-id-123", reviewer_id: "example")
    updated = ComplianceReview.find(agg.id)
    expect(updated.status).to eq("open")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("OpenedReview")
  end

  it "ApproveReview transitions to 'approved'" do
    agg = ComplianceReview.open(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example"
        )
    ComplianceReview.open(model_id: "example", policy_id: "ref-id-123", reviewer_id: "example")
    ComplianceReview.approve(review_id: agg.id, notes: "example")
    updated = ComplianceReview.find(agg.id)
    expect(updated.status).to eq("approved")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("ApprovedReview")
  end

  it "RejectReview transitions to 'rejected'" do
    agg = ComplianceReview.open(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example"
        )
    ComplianceReview.open(model_id: "example", policy_id: "ref-id-123", reviewer_id: "example")
    ComplianceReview.approve(review_id: agg.id, notes: "example")
    ComplianceReview.reject(review_id: agg.id, notes: "example")
    updated = ComplianceReview.find(agg.id)
    expect(updated.status).to eq("rejected")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RejectedReview")
  end

  it "RequestChanges transitions to 'changes_requested'" do
    agg = ComplianceReview.open(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example"
        )
    ComplianceReview.open(model_id: "example", policy_id: "ref-id-123", reviewer_id: "example")
    ComplianceReview.approve(review_id: agg.id, notes: "example")
    ComplianceReview.reject(review_id: agg.id, notes: "example")
    ComplianceReview.request_changes(review_id: agg.id, notes: "example")
    updated = ComplianceReview.find(agg.id)
    expect(updated.status).to eq("changes_requested")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RequestedChanges")
  end

  it "generates status predicates" do
    agg = ComplianceReview.open(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example"
        )
    expect(agg.open?).to be true
    expect(agg.approved?).to be false
    expect(agg.rejected?).to be false
  end
end
