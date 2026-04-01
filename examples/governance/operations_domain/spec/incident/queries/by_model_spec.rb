require_relative "../../spec_helper"

RSpec.describe "Incident.by_model" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = Incident.by_model("example")
    expect(results).to be_an(Array)
  end
end
