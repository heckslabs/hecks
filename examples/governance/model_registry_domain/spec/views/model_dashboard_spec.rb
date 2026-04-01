require_relative "../spec_helper"

RSpec.describe "ModelDashboard view" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts with empty state" do
    expect(ModelRegistryDomain::ModelDashboard.current).to eq({})
  end

  it "projects RegisteredModel events" do
    AiModel.register(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        )
    state = ModelRegistryDomain::ModelDashboard.current
    expect(state).not_to eq({})
  end

  it "projects ClassifiedRisk events" do
    AiModel.classify_risk(model_id: "example", risk_level: "example")
    state = ModelRegistryDomain::ModelDashboard.current
    expect(state).not_to eq({})
  end

  it "projects SuspendedModel events" do
    AiModel.suspend(model_id: "example")
    state = ModelRegistryDomain::ModelDashboard.current
    expect(state).not_to eq({})
  end

end
