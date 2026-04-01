require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::ComplianceReview::Events::RejectedReview do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          review_id: "example",
          notes: "example",
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example",
          outcome: "approved",
          completed_at: DateTime.now,
          conditions: [],
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

  it "carries review_id" do
    expect(event.review_id).to eq("example")
  end

  it "carries notes" do
    expect(event.notes).to eq("example")
  end

  it "carries model_id" do
    expect(event.model_id).to eq("example")
  end

  it "carries policy_id" do
    expect(event.policy_id).to eq("ref-id-123")
  end

  it "carries reviewer_id" do
    expect(event.reviewer_id).to eq("example")
  end

  it "carries outcome" do
    expect(event.outcome).to eq("approved")
  end

  it "carries completed_at" do
    expect(event.completed_at).not_to be_nil
  end

  it "carries conditions" do
    expect(event.conditions).to eq([])
  end

  it "carries status" do
    expect(event.status).to eq("example")
  end
end
