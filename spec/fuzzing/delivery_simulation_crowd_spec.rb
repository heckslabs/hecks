require "spec_helper"
require_relative "../support/simulated_delivery"

# A hundred agents landing and boarding at once, with faults drawn into the schedule.
RSpec.describe "A delivery simulation of 100 agents", :aggregate_failures do
  include SimulatedDelivery

  it "holds every invariant under held stores, red main and CI that never starts" do
    results = [1, 2].map { |seed| crowd(seed) }

    expect(results.map { |result| result.agents.size }).to eq([100, 100])
    expect(results.flat_map(&:divergences)).to eq([])
  end

  it "meets every way a landing and a boarding can end" do
    outcomes = crowd(1).outcomes.values

    expect(outcomes.map(&:first).uniq).to match_array(%w[landed refused])
    expect(outcomes.map(&:last).uniq).to include("pushed", "carried", "faulted", "queued", "red")
  end
end
