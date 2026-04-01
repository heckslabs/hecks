require_relative "../spec_helper"

RSpec.describe ModelRegistryDomain::DataUsageAgreement do
  describe "creating a DataUsageAgreement" do
    subject(:data_usage_agreement) { described_class.new(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "public_domain",
          effective_date: Date.today,
          expiration_date: Date.today,
          restrictions: [],
          status: "example"
        ) }

    it "assigns an id" do
      expect(data_usage_agreement.id).not_to be_nil
    end

    it "sets model_id" do
      expect(data_usage_agreement.model_id).to eq("ref-id-123")
    end

    it "sets data_source" do
      expect(data_usage_agreement.data_source).to eq("example")
    end

    it "sets purpose" do
      expect(data_usage_agreement.purpose).to eq("example")
    end

    it "sets consent_type" do
      expect(data_usage_agreement.consent_type).to eq("public_domain")
    end

    it "sets effective_date" do
      expect(data_usage_agreement.effective_date).not_to be_nil
    end

    it "sets expiration_date" do
      expect(data_usage_agreement.expiration_date).not_to be_nil
    end

    it "sets restrictions" do
      expect(data_usage_agreement.restrictions).to eq([])
    end

    it "sets status" do
      expect(data_usage_agreement.status).to eq("example")
    end
  end

  describe "data_source validation" do
    it "rejects nil data_source" do
      expect {
        described_class.new(
          model_id: "ref-id-123",
          data_source: nil,
          purpose: "example",
          consent_type: "public_domain",
          effective_date: Date.today,
          expiration_date: Date.today,
          restrictions: [],
          status: "example"
        )
      }.to raise_error(ModelRegistryDomain::ValidationError, /data_source/)
    end
  end

  describe "purpose validation" do
    it "rejects nil purpose" do
      expect {
        described_class.new(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: nil,
          consent_type: "public_domain",
          effective_date: Date.today,
          expiration_date: Date.today,
          restrictions: [],
          status: "example"
        )
      }.to raise_error(ModelRegistryDomain::ValidationError, /purpose/)
    end
  end

  describe "invariant: expiration must be after effective date" do
    it "raises InvariantError when violated" do
      # TODO: construct an instance that violates: expiration must be after effective date
      # expect { described_class.new(...) }.to raise_error(ModelRegistryDomain::InvariantError)
    end
  end

  describe "identity" do
    it "two DataUsageAgreements with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "public_domain",
          effective_date: Date.today,
          expiration_date: Date.today,
          restrictions: [],
          status: "example",
          id: id
        )
      b = described_class.new(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "public_domain",
          effective_date: Date.today,
          expiration_date: Date.today,
          restrictions: [],
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two DataUsageAgreements with different ids are not equal" do
      a = described_class.new(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "public_domain",
          effective_date: Date.today,
          expiration_date: Date.today,
          restrictions: [],
          status: "example"
        )
      b = described_class.new(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "public_domain",
          effective_date: Date.today,
          expiration_date: Date.today,
          restrictions: [],
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
