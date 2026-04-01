require_relative "../spec_helper"

RSpec.describe ModelRegistryDomain::Vendor do
  describe "creating a Vendor" do
    subject(:vendor) { described_class.new(
          name: "example",
          contact_email: "example",
          risk_tier: "low",
          assessment_date: Date.today,
          next_review_date: Date.today,
          sla_terms: "example",
          status: "example"
        ) }

    it "assigns an id" do
      expect(vendor.id).not_to be_nil
    end

    it "sets name" do
      expect(vendor.name).to eq("example")
    end

    it "sets contact_email" do
      expect(vendor.contact_email).to eq("example")
    end

    it "sets risk_tier" do
      expect(vendor.risk_tier).to eq("low")
    end

    it "sets assessment_date" do
      expect(vendor.assessment_date).not_to be_nil
    end

    it "sets next_review_date" do
      expect(vendor.next_review_date).not_to be_nil
    end

    it "sets sla_terms" do
      expect(vendor.sla_terms).to eq("example")
    end

    it "sets status" do
      expect(vendor.status).to eq("example")
    end
  end

  describe "name validation" do
    it "rejects nil name" do
      expect {
        described_class.new(
          name: nil,
          contact_email: "example",
          risk_tier: "low",
          assessment_date: Date.today,
          next_review_date: Date.today,
          sla_terms: "example",
          status: "example"
        )
      }.to raise_error(ModelRegistryDomain::ValidationError, /name/)
    end
  end

  describe "identity" do
    it "two Vendors with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          name: "example",
          contact_email: "example",
          risk_tier: "low",
          assessment_date: Date.today,
          next_review_date: Date.today,
          sla_terms: "example",
          status: "example",
          id: id
        )
      b = described_class.new(
          name: "example",
          contact_email: "example",
          risk_tier: "low",
          assessment_date: Date.today,
          next_review_date: Date.today,
          sla_terms: "example",
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Vendors with different ids are not equal" do
      a = described_class.new(
          name: "example",
          contact_email: "example",
          risk_tier: "low",
          assessment_date: Date.today,
          next_review_date: Date.today,
          sla_terms: "example",
          status: "example"
        )
      b = described_class.new(
          name: "example",
          contact_email: "example",
          risk_tier: "low",
          assessment_date: Date.today,
          next_review_date: Date.today,
          sla_terms: "example",
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
