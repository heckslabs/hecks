require_relative "../../spec_helper"

RSpec.describe "Assessment.submitted" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns only Assessments matching status: "submitted"" do
    Assessment.initiate(model_id: "example", assessor_id: "example")
    Assessment.initiate(model_id: "example", assessor_id: "example")
    results = Assessment.submitted
    expect(results).to be_an(Array)
    expect(results.all? { |r| r.status == "submitted" }).to be true
  end
end
