require_relative "../../spec_helper"

RSpec.describe "GovernancePolicy.active_policies" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns only GovernancePolicys matching status: "active"" do
    GovernancePolicy.create(name: "example", description: "example", category: "example", framework_id: "ref-id-123")
    GovernancePolicy.create(name: "example", description: "example", category: "example", framework_id: "ref-id-123")
    results = GovernancePolicy.active_policies
    expect(results).to be_an(Array)
    expect(results.all? { |r| r.status == "active" }).to be true
  end
end
