require_relative "../../spec_helper"

RSpec.describe "Deployment.customer_facing" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns only Deployments matching audience: "customer-facing"" do
    Deployment.plan(model_id: "example", environment: "example", endpoint: "example", purpose: "example", audience: "customer-facing")
    Deployment.plan(model_id: "example", environment: "example", endpoint: "example", purpose: "example", audience: "other")
    results = Deployment.customer_facing
    expect(results).to be_an(Array)
    expect(results.all? { |r| r.audience == "customer-facing" }).to be true
  end
end
