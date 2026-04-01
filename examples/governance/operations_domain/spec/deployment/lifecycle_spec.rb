require_relative "../spec_helper"

RSpec.describe "Deployment lifecycle" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts in 'planned' state" do
    agg = Deployment.plan(
          model_id: "example",
          environment: "example",
          endpoint: "example",
          purpose: "example",
          audience: "example"
        )
    expect(agg.status).to eq("planned")
  end

  it "PlanDeployment transitions to 'planned'" do
    agg = Deployment.plan(
          model_id: "example",
          environment: "example",
          endpoint: "example",
          purpose: "example",
          audience: "example"
        )
    Deployment.plan(model_id: "example", environment: "example", endpoint: "example", purpose: "example", audience: "example")
    updated = Deployment.find(agg.id)
    expect(updated.status).to eq("planned")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("PlannedDeployment")
  end

  it "DeployModel transitions to 'deployed'" do
    agg = Deployment.plan(
          model_id: "example",
          environment: "example",
          endpoint: "example",
          purpose: "example",
          audience: "example"
        )
    Deployment.plan(model_id: "example", environment: "example", endpoint: "example", purpose: "example", audience: "example")
    Deployment.deploy_model(deployment_id: agg.id)
    updated = Deployment.find(agg.id)
    expect(updated.status).to eq("deployed")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("DeployedModel")
  end

  it "DecommissionDeployment transitions to 'decommissioned'" do
    agg = Deployment.plan(
          model_id: "example",
          environment: "example",
          endpoint: "example",
          purpose: "example",
          audience: "example"
        )
    Deployment.plan(model_id: "example", environment: "example", endpoint: "example", purpose: "example", audience: "example")
    Deployment.deploy_model(deployment_id: agg.id)
    Deployment.decommission(deployment_id: agg.id)
    updated = Deployment.find(agg.id)
    expect(updated.status).to eq("decommissioned")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("DecommissionedDeployment")
  end

  it "generates status predicates" do
    agg = Deployment.plan(
          model_id: "example",
          environment: "example",
          endpoint: "example",
          purpose: "example",
          audience: "example"
        )
    expect(agg.planned?).to be true
    expect(agg.deployed?).to be false
    expect(agg.decommissioned?).to be false
  end
end
