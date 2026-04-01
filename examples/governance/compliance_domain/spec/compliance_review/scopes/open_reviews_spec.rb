require_relative "../../spec_helper"

RSpec.describe "ComplianceReview.open_reviews" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns only ComplianceReviews matching status: "open"" do
    ComplianceReview.open(model_id: "example", policy_id: "ref-id-123", reviewer_id: "example")
    ComplianceReview.open(model_id: "example", policy_id: "ref-id-123", reviewer_id: "example")
    results = ComplianceReview.open_reviews
    expect(results).to be_an(Array)
    expect(results.all? { |r| r.status == "open" }).to be true
  end
end
