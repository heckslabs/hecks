require_relative "../../spec_helper"

RSpec.describe "AiModel.by_status" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = AiModel.by_status("example")
    expect(results).to be_an(Array)
  end
end
