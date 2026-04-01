require_relative "../../spec_helper"

RSpec.describe "Stakeholder.admins" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns only Stakeholders matching role: "admin"" do
    Stakeholder.register(name: "example", email: "example", role: "admin", team: "example")
    Stakeholder.register(name: "example", email: "example", role: "other", team: "example")
    results = Stakeholder.admins
    expect(results).to be_an(Array)
    expect(results.all? { |r| r.role == "admin" }).to be true
  end
end
