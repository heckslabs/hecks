require_relative "../../spec_helper"

RSpec.describe "Stakeholder.auditors" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns only Stakeholders matching role: "auditor"" do
    Stakeholder.register(name: "example", email: "example", role: "auditor", team: "example")
    Stakeholder.register(name: "example", email: "example", role: "other", team: "example")
    results = Stakeholder.auditors
    expect(results).to be_an(Array)
    expect(results.all? { |r| r.role == "auditor" }).to be true
  end
end
