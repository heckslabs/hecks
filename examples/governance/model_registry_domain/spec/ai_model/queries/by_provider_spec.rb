require_relative "../../spec_helper"

RSpec.describe "AiModel.by_provider" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = AiModel.by_provider("example")
    expect(results).to be_an(Array)
  end
end
