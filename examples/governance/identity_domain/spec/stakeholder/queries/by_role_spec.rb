require_relative "../../spec_helper"

RSpec.describe "Stakeholder.by_role" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = Stakeholder.by_role("example")
    expect(results).to be_an(Array)
  end
end
