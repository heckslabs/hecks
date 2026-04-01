require_relative "../../spec_helper"

RSpec.describe "Incident.open_incidents" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns only Incidents matching status: "reported"" do
    Incident.report(model_id: "example", severity: "example", category: "example", description: "example", reported_by_id: "example")
    Incident.report(model_id: "example", severity: "example", category: "example", description: "example", reported_by_id: "example")
    results = Incident.open_incidents
    expect(results).to be_an(Array)
    expect(results.all? { |r| r.status == "reported" }).to be true
  end
end
