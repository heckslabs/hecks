require_relative "../spec_helper"

RSpec.describe ModelRegistryDomain::AiModel do
  describe "creating a AiModel" do
    subject(:ai_model) { described_class.new(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example",
          risk_level: "low",
          registered_at: DateTime.now,
          parent_model_id: "example",
          derivation_type: "fine-tuned",
          capabilities: [],
          intended_uses: [],
          status: "example"
        ) }

    it "assigns an id" do
      expect(ai_model.id).not_to be_nil
    end

    it "sets name" do
      expect(ai_model.name).to eq("example")
    end

    it "sets version" do
      expect(ai_model.version).to eq("example")
    end

    it "sets provider_id" do
      expect(ai_model.provider_id).to eq("ref-id-123")
    end

    it "sets description" do
      expect(ai_model.description).to eq("example")
    end

    it "sets risk_level" do
      expect(ai_model.risk_level).to eq("low")
    end

    it "sets registered_at" do
      expect(ai_model.registered_at).not_to be_nil
    end

    it "sets parent_model_id" do
      expect(ai_model.parent_model_id).to eq("example")
    end

    it "sets derivation_type" do
      expect(ai_model.derivation_type).to eq("fine-tuned")
    end

    it "sets capabilities" do
      expect(ai_model.capabilities).to eq([])
    end

    it "sets intended_uses" do
      expect(ai_model.intended_uses).to eq([])
    end

    it "sets status" do
      expect(ai_model.status).to eq("example")
    end
  end

  describe "name validation" do
    it "rejects nil name" do
      expect {
        described_class.new(
          name: nil,
          version: "example",
          provider_id: "ref-id-123",
          description: "example",
          risk_level: "low",
          registered_at: DateTime.now,
          parent_model_id: "example",
          derivation_type: "fine-tuned",
          capabilities: [],
          intended_uses: [],
          status: "example"
        )
      }.to raise_error(ModelRegistryDomain::ValidationError, /name/)
    end
  end

  describe "version validation" do
    it "rejects nil version" do
      expect {
        described_class.new(
          name: "example",
          version: nil,
          provider_id: "ref-id-123",
          description: "example",
          risk_level: "low",
          registered_at: DateTime.now,
          parent_model_id: "example",
          derivation_type: "fine-tuned",
          capabilities: [],
          intended_uses: [],
          status: "example"
        )
      }.to raise_error(ModelRegistryDomain::ValidationError, /version/)
    end
  end

  describe "identity" do
    it "two AiModels with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example",
          risk_level: "low",
          registered_at: DateTime.now,
          parent_model_id: "example",
          derivation_type: "fine-tuned",
          capabilities: [],
          intended_uses: [],
          status: "example",
          id: id
        )
      b = described_class.new(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example",
          risk_level: "low",
          registered_at: DateTime.now,
          parent_model_id: "example",
          derivation_type: "fine-tuned",
          capabilities: [],
          intended_uses: [],
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two AiModels with different ids are not equal" do
      a = described_class.new(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example",
          risk_level: "low",
          registered_at: DateTime.now,
          parent_model_id: "example",
          derivation_type: "fine-tuned",
          capabilities: [],
          intended_uses: [],
          status: "example"
        )
      b = described_class.new(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example",
          risk_level: "low",
          registered_at: DateTime.now,
          parent_model_id: "example",
          derivation_type: "fine-tuned",
          capabilities: [],
          intended_uses: [],
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
