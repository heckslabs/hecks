require "spec_helper"
require_relative "../support/simulated_delivery"

# One agent, or a hundred, with a fault switched on in the simulated world: what the `Landing`
# and `SendTrain` bluebooks record of it.
RSpec.describe "A delivery simulation with a fault in the world", :aggregate_failures do
  include SimulatedDelivery

  it "records a red main as a refused landing and a faulted boarding" do
    result = simulation.run(faulted("red_main", "a"))

    expect(result.outcomes).to eq("a" => %w[refused faulted])
    expect(result.divergences).to eq([])
  end

  it "leaves a boarding queued when its CI never starts, with nothing unfinished" do
    result = simulation.run(faulted("ci_never_starts", "a"))

    expect(result.outcomes).to eq("a" => %w[landed queued])
    expect(result.divergences).to eq([])
  end

  it "records a boarding whose CI failed as red" do
    expect(simulation.run(faulted("ci_red", "a")).outcomes).to eq("a" => %w[landed red])
  end

  it "keeps the train's answer when the store that records the outcome is held" do
    result = simulation.run(faulted("hold_store", "a"))

    expect(result.outcomes).to eq("a" => %w[landed pushed])
    expect(result.divergences).to eq([])
  end
end
