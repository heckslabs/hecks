require_relative "../../spec_helper"

RSpec.describe "Order.pending" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = Order.pending
    expect(results).to be_an(Array)
  end
end
