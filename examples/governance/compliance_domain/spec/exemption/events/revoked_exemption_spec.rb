require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::Exemption::Events::RevokedExemption do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          exemption_id: "example",
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example",
          approved_by_id: "example",
          approved_at: DateTime.now,
          expires_at: Date.today,
          scope: "example",
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

  it "carries exemption_id" do
    expect(event.exemption_id).to eq("example")
  end

  it "carries model_id" do
    expect(event.model_id).to eq("example")
  end

  it "carries policy_id" do
    expect(event.policy_id).to eq("ref-id-123")
  end

  it "carries requirement" do
    expect(event.requirement).to eq("example")
  end

  it "carries reason" do
    expect(event.reason).to eq("example")
  end

  it "carries approved_by_id" do
    expect(event.approved_by_id).to eq("example")
  end

  it "carries approved_at" do
    expect(event.approved_at).not_to be_nil
  end

  it "carries expires_at" do
    expect(event.expires_at).not_to be_nil
  end

  it "carries scope" do
    expect(event.scope).to eq("example")
  end

  it "carries status" do
    expect(event.status).to eq("example")
  end
end
