require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::AiModel::Events::RetiredModel do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          model_id: "example",
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

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries aggregate_id" do
    expect(event.aggregate_id).to eq("example")
  end

  it "carries model_id" do
    expect(event.model_id).to eq("example")
  end

  it "carries name" do
    expect(event.name).to eq("example")
  end

  it "carries version" do
    expect(event.version).to eq("example")
  end

  it "carries provider_id" do
    expect(event.provider_id).to eq("ref-id-123")
  end

  it "carries description" do
    expect(event.description).to eq("example")
  end

  it "carries risk_level" do
    expect(event.risk_level).to eq("low")
  end

  it "carries registered_at" do
    expect(event.registered_at).not_to be_nil
  end

  it "carries parent_model_id" do
    expect(event.parent_model_id).to eq("example")
  end

  it "carries derivation_type" do
    expect(event.derivation_type).to eq("fine-tuned")
  end

  it "carries capabilities" do
    expect(event.capabilities).to eq([])
  end

  it "carries intended_uses" do
    expect(event.intended_uses).to eq([])
  end

  it "carries status" do
    expect(event.status).to eq("example")
  end
end
