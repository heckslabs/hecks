require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::ComplianceReview::Commands::ApproveReview do
  describe "attributes" do
    subject(:command) { described_class.new(review_id: "example", notes: "example") }

    it "has review_id" do
      expect(command.review_id).to eq("example")
    end

    it "has notes" do
      expect(command.notes).to eq("example")
    end

  end

  describe "event" do
    it "emits ApprovedReview" do
      expect(described_class.event_name).to eq("ApprovedReview")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits ApprovedReview" do
      agg = ComplianceReview.open(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example"
        )
      ComplianceReview.approve(review_id: "example", notes: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("ApprovedReview")
    end
  end
end
