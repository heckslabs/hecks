require "spec_helper"
require_relative "support/machine_readings"

# Memory is read as swap used in megabytes, the compressor's size and free memory;
# the test lane as its waiting count.
RSpec.describe "the memory and lane states of a machine reading" do
  include MachineReadings

  it "runs memory low over the swap or compressor mark while free memory is short", :aggregate_failures do
    expect(states(gauges(swap_mb: 5000.0, free: 1.0))[:memory_state]).to eq("low")
    expect(states(gauges(compressor: 17.0, free: 1.0))[:memory_state]).to eq("low")
  end

  it "does not run memory low on large idle swap or a big compressor with free memory", :aggregate_failures do
    expect(states(gauges(swap_mb: 5000.0, free: 13.0))[:memory_state]).to eq("ok")
    expect(states(gauges(compressor: 17.0, free: 13.0))[:memory_state]).to eq("ok")
  end

  it "recovers memory when free memory is back or swap is small, and keeps low in the gap", :aggregate_failures do
    expect(states(gauges(swap_mb: 5000.0, free: 4.0), memory: "low")[:memory_state]).to eq("low")
    expect(states(gauges(swap_mb: 5000.0, free: 8.0), memory: "low")[:memory_state]).to eq("ok")
    expect(states(gauges(swap_mb: 1000.0, free: 1.0), memory: "low")[:memory_state]).to eq("ok")
  end

  it "keeps the lane's state when the queue cannot be read" do
    expect(states(gauges(lane: nil), lane: "busy")[:lane_state]).to eq("busy")
  end

  it "turns the lane busy and idle on its marks", :aggregate_failures do
    expect(states(gauges(lane: 6.0))[:lane_state]).to eq("busy")
    expect(states(gauges(lane: 0.0), lane: "busy")[:lane_state]).to eq("idle")
  end
end
