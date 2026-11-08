require "spec_helper"
require_relative "support/machine_readings"

# The CPU idle percentage decides the load; marks with a gap keep a hovering gauge from flapping.
RSpec.describe "the load state of a machine reading" do
  include MachineReadings

  it "does not call a swap-inflated load average a busy machine while the CPU is idle" do
    expect(states(gauges(idle: 60.1, load: 13.6))[:load_state]).to eq("below")
  end

  it "rises at a busy CPU and falls at an idle one" do
    expect(loads([60.0, 20.0, 30.0, 45.0])).to eq(%w[below above above below])
  end

  it "keeps its state for a series that flaps inside the gap" do
    expect(loads([20.0, 30.0, 38.0, 28.0, 35.0])).to eq(%w[above above above above above])
  end

  it "lets the load average tip the state only when the CPU is not idle" do
    expect(states(gauges(idle: 30.0, load: 12.0))[:load_state]).to eq("above")
  end

  it "says the state each gauge stood in before" do
    expect(states(gauges(idle: 10.0), load: "below")).to include(load_before: "below", load_state: "above")
  end
end
