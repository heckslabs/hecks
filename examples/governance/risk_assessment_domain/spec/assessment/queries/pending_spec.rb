require_relative "../../spec_helper"

RSpec.describe "Assessment.pending" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = Assessment.pending
    expect(results).to be_an(Array)
  end
end
