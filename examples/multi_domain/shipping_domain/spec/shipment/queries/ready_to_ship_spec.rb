require_relative "../../spec_helper"

RSpec.describe "Shipment.ready_to_ship" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = Shipment.ready_to_ship
    expect(results).to be_an(Array)
  end
end
