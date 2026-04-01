require_relative "../../spec_helper"

RSpec.describe "Pizza.by_description" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = Pizza.by_description("example")
    expect(results).to be_an(Array)
  end
end
