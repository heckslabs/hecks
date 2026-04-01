require_relative "../../spec_helper"

RSpec.describe "Deployment.active" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = Deployment.active
    expect(results).to be_an(Array)
  end
end
