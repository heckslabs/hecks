require_relative "../../spec_helper"

RSpec.describe "Deployment.production" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns only Deployments matching environment: "production"" do
    Deployment.plan(model_id: "example", environment: "production", endpoint: "example", purpose: "example", audience: "example")
    Deployment.plan(model_id: "example", environment: "other", endpoint: "example", purpose: "example", audience: "example")
    results = Deployment.production
    expect(results).to be_an(Array)
    expect(results.all? { |r| r.environment == "production" }).to be true
  end
end
