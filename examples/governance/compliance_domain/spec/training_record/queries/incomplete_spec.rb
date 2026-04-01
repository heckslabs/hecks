require_relative "../../spec_helper"

RSpec.describe "TrainingRecord.incomplete" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = TrainingRecord.incomplete
    expect(results).to be_an(Array)
  end
end
