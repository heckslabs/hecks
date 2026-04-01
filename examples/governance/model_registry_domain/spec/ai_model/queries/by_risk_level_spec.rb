require_relative "../../spec_helper"

RSpec.describe "AiModel.by_risk_level" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = AiModel.by_risk_level("example")
    expect(results).to be_an(Array)
  end
end
