require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::GovernancePolicy::Events::UpdatedReviewDate do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          policy_id: "example",
          review_date: Date.today,
          name: "example",
          description: "example",
          category: "regulatory",
          framework_id: "ref-id-123",
          effective_date: Date.today,
          requirements: [],
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

  it "carries policy_id" do
    expect(event.policy_id).to eq("example")
  end

  it "carries review_date" do
    expect(event.review_date).not_to be_nil
  end

  it "carries name" do
    expect(event.name).to eq("example")
  end

  it "carries description" do
    expect(event.description).to eq("example")
  end

  it "carries category" do
    expect(event.category).to eq("regulatory")
  end

  it "carries framework_id" do
    expect(event.framework_id).to eq("ref-id-123")
  end

  it "carries effective_date" do
    expect(event.effective_date).not_to be_nil
  end

  it "carries requirements" do
    expect(event.requirements).to eq([])
  end

  it "carries status" do
    expect(event.status).to eq("example")
  end
end
