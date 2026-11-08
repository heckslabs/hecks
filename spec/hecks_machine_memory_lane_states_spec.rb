require "spec_helper"
require_relative "support/machine_readings"

# Memory is read as swap used and the compressor's size; the test lane as its waiting count.
RSpec.describe "the memory and lane states of a machine reading" do
  include MachineReadings

  it "runs memory low over the swap mark or the compressor mark", :aggregate_failures do
    expect(states(gauges(swap: 86.0))[:memory_state]).to eq("low")
    expect(states(gauges(compressor: 17.0))[:memory_state]).to eq("low")
  end

  it "recovers memory only under the recovery mark", :aggregate_failures do
    expect(states(gauges(swap: 60.0), memory: "low")[:memory_state]).to eq("low")
    expect(states(gauges(swap: 40.0), memory: "low")[:memory_state]).to eq("ok")
  end

  it "keeps the lane's state when the queue cannot be read" do
    expect(states(gauges(lane: nil), lane: "busy")[:lane_state]).to eq("busy")
  end

  it "turns the lane busy and idle on its marks", :aggregate_failures do
    expect(states(gauges(lane: 6.0))[:lane_state]).to eq("busy")
    expect(states(gauges(lane: 0.0), lane: "busy")[:lane_state]).to eq("idle")
  end
end
