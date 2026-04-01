require_relative "../../spec_helper"

RSpec.describe "TrainingRecord.by_policy" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = TrainingRecord.by_policy("example")
    expect(results).to be_an(Array)
  end
end
