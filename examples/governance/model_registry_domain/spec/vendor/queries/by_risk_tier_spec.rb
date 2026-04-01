require_relative "../../spec_helper"

RSpec.describe "Vendor.by_risk_tier" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = Vendor.by_risk_tier("example")
    expect(results).to be_an(Array)
  end
end
