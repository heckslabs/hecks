require_relative "../../spec_helper"

RSpec.describe "GovernancePolicy.by_category" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = GovernancePolicy.by_category("example")
    expect(results).to be_an(Array)
  end
end
