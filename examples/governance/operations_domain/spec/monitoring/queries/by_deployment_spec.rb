require_relative "../../spec_helper"

RSpec.describe "Monitoring.by_deployment" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = Monitoring.by_deployment("example")
    expect(results).to be_an(Array)
  end
end
