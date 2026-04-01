require_relative "../spec_helper"

RSpec.describe ComplianceDomain::Exemption do
  describe "creating a Exemption" do
    subject(:exemption) { described_class.new(
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

    it "assigns an id" do
      expect(exemption.id).not_to be_nil
    end

    it "sets model_id" do
      expect(exemption.model_id).to eq("example")
    end

    it "sets policy_id" do
      expect(exemption.policy_id).to eq("ref-id-123")
    end

    it "sets requirement" do
      expect(exemption.requirement).to eq("example")
    end

    it "sets reason" do
      expect(exemption.reason).to eq("example")
    end

    it "sets approved_by_id" do
      expect(exemption.approved_by_id).to eq("example")
    end

    it "sets approved_at" do
      expect(exemption.approved_at).not_to be_nil
    end

    it "sets expires_at" do
      expect(exemption.expires_at).not_to be_nil
    end

    it "sets scope" do
      expect(exemption.scope).to eq("example")
    end

    it "sets status" do
      expect(exemption.status).to eq("example")
    end
  end

  describe "model_id validation" do
    it "rejects nil model_id" do
      expect {
        described_class.new(
          model_id: nil,
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example",
          approved_by_id: "example",
          approved_at: DateTime.now,
          expires_at: Date.today,
          scope: "example",
          status: "example"
        )
      }.to raise_error(ComplianceDomain::ValidationError, /model_id/)
    end
  end

  describe "policy_id validation" do
    it "rejects nil policy_id" do
      expect {
        described_class.new(
          model_id: "example",
          policy_id: nil,
          requirement: "example",
          reason: "example",
          approved_by_id: "example",
          approved_at: DateTime.now,
          expires_at: Date.today,
          scope: "example",
          status: "example"
        )
      }.to raise_error(ComplianceDomain::ValidationError, /policy_id/)
    end
  end

  describe "identity" do
    it "two Exemptions with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example",
          approved_by_id: "example",
          approved_at: DateTime.now,
          expires_at: Date.today,
          scope: "example",
          status: "example",
          id: id
        )
      b = described_class.new(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example",
          approved_by_id: "example",
          approved_at: DateTime.now,
          expires_at: Date.today,
          scope: "example",
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Exemptions with different ids are not equal" do
      a = described_class.new(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example",
          approved_by_id: "example",
          approved_at: DateTime.now,
          expires_at: Date.today,
          scope: "example",
          status: "example"
        )
      b = described_class.new(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example",
          approved_by_id: "example",
          approved_at: DateTime.now,
          expires_at: Date.today,
          scope: "example",
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
