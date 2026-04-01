require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::TrainingRecord::Events::RenewedTraining do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          training_record_id: "example",
          certification: "example",
          expires_at: Date.today,
          stakeholder_id: "example",
          policy_id: "ref-id-123",
          completed_at: DateTime.now,
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

  it "carries training_record_id" do
    expect(event.training_record_id).to eq("example")
  end

  it "carries certification" do
    expect(event.certification).to eq("example")
  end

  it "carries expires_at" do
    expect(event.expires_at).not_to be_nil
  end

  it "carries stakeholder_id" do
    expect(event.stakeholder_id).to eq("example")
  end

  it "carries policy_id" do
    expect(event.policy_id).to eq("ref-id-123")
  end

  it "carries completed_at" do
    expect(event.completed_at).not_to be_nil
  end

  it "carries status" do
    expect(event.status).to eq("example")
  end
end
