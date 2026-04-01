require_relative "../spec_helper"

RSpec.describe "AiModel lifecycle" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts in 'draft' state" do
    agg = AiModel.register(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        )
    expect(agg.status).to eq("draft")
  end

  it "RegisterModel transitions to 'draft'" do
    agg = AiModel.register(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        )
    AiModel.register(name: "example", version: "example", provider_id: "ref-id-123", description: "example")
    updated = AiModel.find(agg.id)
    expect(updated.status).to eq("draft")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RegisteredModel")
  end

  it "DeriveModel transitions to 'draft'" do
    agg = AiModel.register(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        )
    AiModel.derive(name: "example", version: "example", parent_model_id: "example", derivation_type: "example", description: "example")
    updated = AiModel.find(agg.id)
    expect(updated.status).to eq("draft")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("DerivedModel")
  end

  it "ClassifyRisk transitions to 'classified'" do
    agg = AiModel.register(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        )
    AiModel.register(name: "example", version: "example", provider_id: "ref-id-123", description: "example")
    AiModel.derive(name: "example", version: "example", parent_model_id: "example", derivation_type: "example", description: "example")
    AiModel.classify_risk(model_id: agg.id, risk_level: "example")
    updated = AiModel.find(agg.id)
    expect(updated.status).to eq("classified")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("ClassifiedRisk")
  end

  it "ApproveModel transitions to 'approved'" do
    agg = AiModel.register(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        )
    AiModel.register(name: "example", version: "example", provider_id: "ref-id-123", description: "example")
    AiModel.derive(name: "example", version: "example", parent_model_id: "example", derivation_type: "example", description: "example")
    AiModel.classify_risk(model_id: agg.id, risk_level: "example")
    AiModel.approve(model_id: agg.id)
    updated = AiModel.find(agg.id)
    expect(updated.status).to eq("approved")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("ApprovedModel")
  end

  it "SuspendModel transitions to 'suspended'" do
    agg = AiModel.register(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        )
    AiModel.register(name: "example", version: "example", provider_id: "ref-id-123", description: "example")
    AiModel.derive(name: "example", version: "example", parent_model_id: "example", derivation_type: "example", description: "example")
    AiModel.classify_risk(model_id: agg.id, risk_level: "example")
    AiModel.approve(model_id: agg.id)
    AiModel.suspend(model_id: agg.id)
    updated = AiModel.find(agg.id)
    expect(updated.status).to eq("suspended")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("SuspendedModel")
  end

  it "RetireModel transitions to 'retired'" do
    agg = AiModel.register(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        )
    AiModel.register(name: "example", version: "example", provider_id: "ref-id-123", description: "example")
    AiModel.derive(name: "example", version: "example", parent_model_id: "example", derivation_type: "example", description: "example")
    AiModel.classify_risk(model_id: agg.id, risk_level: "example")
    AiModel.approve(model_id: agg.id)
    AiModel.suspend(model_id: agg.id)
    AiModel.retire(model_id: agg.id)
    updated = AiModel.find(agg.id)
    expect(updated.status).to eq("retired")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RetiredModel")
  end

  it "generates status predicates" do
    agg = AiModel.register(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        )
    expect(agg.draft?).to be true
    expect(agg.classified?).to be false
    expect(agg.approved?).to be false
  end
end
