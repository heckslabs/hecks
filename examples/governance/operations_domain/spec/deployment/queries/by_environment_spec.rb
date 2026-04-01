require_relative "../../spec_helper"

RSpec.describe "Deployment.by_environment" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = Deployment.by_environment("example")
    expect(results).to be_an(Array)
  end
end
