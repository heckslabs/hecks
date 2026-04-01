require_relative "../spec_helper"

RSpec.describe ComplianceDomain::ComplianceReview do
  describe "creating a ComplianceReview" do
    subject(:compliance_review) { described_class.new(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example",
          outcome: "approved",
          notes: "example",
          completed_at: DateTime.now,
          conditions: [],
          status: "example"
        ) }

    it "assigns an id" do
      expect(compliance_review.id).not_to be_nil
    end

    it "sets model_id" do
      expect(compliance_review.model_id).to eq("example")
    end

    it "sets policy_id" do
      expect(compliance_review.policy_id).to eq("ref-id-123")
    end

    it "sets reviewer_id" do
      expect(compliance_review.reviewer_id).to eq("example")
    end

    it "sets outcome" do
      expect(compliance_review.outcome).to eq("approved")
    end

    it "sets notes" do
      expect(compliance_review.notes).to eq("example")
    end

    it "sets completed_at" do
      expect(compliance_review.completed_at).not_to be_nil
    end

    it "sets conditions" do
      expect(compliance_review.conditions).to eq([])
    end

    it "sets status" do
      expect(compliance_review.status).to eq("example")
    end
  end

  describe "model_id validation" do
    it "rejects nil model_id" do
      expect {
        described_class.new(
          model_id: nil,
          policy_id: "ref-id-123",
          reviewer_id: "example",
          outcome: "approved",
          notes: "example",
          completed_at: DateTime.now,
          conditions: [],
          status: "example"
        )
      }.to raise_error(ComplianceDomain::ValidationError, /model_id/)
    end
  end

  describe "reviewer_id validation" do
    it "rejects nil reviewer_id" do
      expect {
        described_class.new(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: nil,
          outcome: "approved",
          notes: "example",
          completed_at: DateTime.now,
          conditions: [],
          status: "example"
        )
      }.to raise_error(ComplianceDomain::ValidationError, /reviewer_id/)
    end
  end

  describe "identity" do
    it "two ComplianceReviews with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example",
          outcome: "approved",
          notes: "example",
          completed_at: DateTime.now,
          conditions: [],
          status: "example",
          id: id
        )
      b = described_class.new(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example",
          outcome: "approved",
          notes: "example",
          completed_at: DateTime.now,
          conditions: [],
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two ComplianceReviews with different ids are not equal" do
      a = described_class.new(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example",
          outcome: "approved",
          notes: "example",
          completed_at: DateTime.now,
          conditions: [],
          status: "example"
        )
      b = described_class.new(
          model_id: "example",
          policy_id: "ref-id-123",
          reviewer_id: "example",
          outcome: "approved",
          notes: "example",
          completed_at: DateTime.now,
          conditions: [],
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
