require_relative "../../spec_helper"

RSpec.describe "Incident.open" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = Incident.open
    expect(results).to be_an(Array)
  end
end
