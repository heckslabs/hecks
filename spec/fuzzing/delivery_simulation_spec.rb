require "spec_helper"
require_relative "../support/simulated_delivery"

RSpec.describe Hecks::Fuzzing::DeliverySimulation, :aggregate_failures do
  include SimulatedDelivery

  it "lands and boards one agent in one runtime, and the push reaches the remote" do
    result = simulation.run(turns("a"))

    expect(result.outcomes).to eq("a" => %w[landed pushed])
    expect(result.divergences).to eq([])
  end

  it "lets a second agent run while the first is inside a port ask, each keeping its own ask" do
    expect(interleaved).to eq([["work/b", true], ["work/a", true]])
  end

  it "replays one schedule the same way twice" do
    schedule = described_class::Generator.call(seed: 7, agents: 12)
    first = simulation.run(schedule).outcomes

    expect(simulation.run(schedule).outcomes).to eq(first)
  end

  it "takes a step it cannot read as no step" do
    odd = [{ "verb" => "advance", "args" => {} }, { "verb" => "fault", "args" => { "kind" => "" } }, { "verb" => "" }]

    expect(simulation.run(odd + turns("a")).outcomes).to eq("a" => %w[landed pushed])
  end
end
