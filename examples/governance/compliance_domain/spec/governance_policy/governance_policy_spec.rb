require_relative "../spec_helper"

RSpec.describe ComplianceDomain::GovernancePolicy do
  describe "creating a GovernancePolicy" do
    subject(:governance_policy) { described_class.new(
          name: "example",
          description: "example",
          category: "regulatory",
          framework_id: "ref-id-123",
          effective_date: Date.today,
          review_date: Date.today,
          requirements: [],
          status: "example"
        ) }

    it "assigns an id" do
      expect(governance_policy.id).not_to be_nil
    end

    it "sets name" do
      expect(governance_policy.name).to eq("example")
    end

    it "sets description" do
      expect(governance_policy.description).to eq("example")
    end

    it "sets category" do
      expect(governance_policy.category).to eq("regulatory")
    end

    it "sets framework_id" do
      expect(governance_policy.framework_id).to eq("ref-id-123")
    end

    it "sets effective_date" do
      expect(governance_policy.effective_date).not_to be_nil
    end

    it "sets review_date" do
      expect(governance_policy.review_date).not_to be_nil
    end

    it "sets requirements" do
      expect(governance_policy.requirements).to eq([])
    end

    it "sets status" do
      expect(governance_policy.status).to eq("example")
    end
  end

  describe "name validation" do
    it "rejects nil name" do
      expect {
        described_class.new(
          name: nil,
          description: "example",
          category: "regulatory",
          framework_id: "ref-id-123",
          effective_date: Date.today,
          review_date: Date.today,
          requirements: [],
          status: "example"
        )
      }.to raise_error(ComplianceDomain::ValidationError, /name/)
    end
  end

  describe "category validation" do
    it "rejects nil category" do
      expect {
        described_class.new(
          name: "example",
          description: "example",
          category: nil,
          framework_id: "ref-id-123",
          effective_date: Date.today,
          review_date: Date.today,
          requirements: [],
          status: "example"
        )
      }.to raise_error(ComplianceDomain::ValidationError, /category/)
    end
  end

  describe "identity" do
    it "two GovernancePolicys with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          name: "example",
          description: "example",
          category: "regulatory",
          framework_id: "ref-id-123",
          effective_date: Date.today,
          review_date: Date.today,
          requirements: [],
          status: "example",
          id: id
        )
      b = described_class.new(
          name: "example",
          description: "example",
          category: "regulatory",
          framework_id: "ref-id-123",
          effective_date: Date.today,
          review_date: Date.today,
          requirements: [],
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two GovernancePolicys with different ids are not equal" do
      a = described_class.new(
          name: "example",
          description: "example",
          category: "regulatory",
          framework_id: "ref-id-123",
          effective_date: Date.today,
          review_date: Date.today,
          requirements: [],
          status: "example"
        )
      b = described_class.new(
          name: "example",
          description: "example",
          category: "regulatory",
          framework_id: "ref-id-123",
          effective_date: Date.today,
          review_date: Date.today,
          requirements: [],
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
