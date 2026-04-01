require_relative "../../spec_helper"

RSpec.describe "RegulatoryFramework.by_jurisdiction" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = RegulatoryFramework.by_jurisdiction("example")
    expect(results).to be_an(Array)
  end
end
