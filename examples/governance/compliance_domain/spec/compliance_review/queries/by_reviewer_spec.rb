require_relative "../../spec_helper"

RSpec.describe "ComplianceReview.by_reviewer" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = ComplianceReview.by_reviewer("example")
    expect(results).to be_an(Array)
  end
end
