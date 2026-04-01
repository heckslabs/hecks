require_relative "../../spec_helper"

RSpec.describe "ComplianceReview.pending" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = ComplianceReview.pending
    expect(results).to be_an(Array)
  end
end
