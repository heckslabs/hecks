require_relative "../../spec_helper"

RSpec.describe "Assessment.rejected" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns only Assessments matching status: "rejected"" do
    Assessment.initiate(model_id: "example", assessor_id: "example")
    Assessment.initiate(model_id: "example", assessor_id: "example")
    results = Assessment.rejected
    expect(results).to be_an(Array)
    expect(results.all? { |r| r.status == "rejected" }).to be true
  end
end
