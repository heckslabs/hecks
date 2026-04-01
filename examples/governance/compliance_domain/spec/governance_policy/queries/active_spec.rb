require_relative "../../spec_helper"

RSpec.describe "GovernancePolicy.active" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = GovernancePolicy.active
    expect(results).to be_an(Array)
  end
end
