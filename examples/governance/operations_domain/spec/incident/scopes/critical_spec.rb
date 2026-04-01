require_relative "../../spec_helper"

RSpec.describe "Incident.critical" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns only Incidents matching severity: "critical"" do
    Incident.report(model_id: "example", severity: "critical", category: "example", description: "example", reported_by_id: "example")
    Incident.report(model_id: "example", severity: "other", category: "example", description: "example", reported_by_id: "example")
    results = Incident.critical
    expect(results).to be_an(Array)
    expect(results.all? { |r| r.severity == "critical" }).to be true
  end
end
