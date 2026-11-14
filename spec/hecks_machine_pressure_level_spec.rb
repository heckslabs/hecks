require "spec_helper"
require_relative "support/machine_readings"

# The OS's own memory pressure level decides whether memory is low: free memory swings with the file
# cache and swap is a share of a file macOS resizes, so neither says a machine is thrashing.
RSpec.describe "the memory state from the OS's pressure level" do
  include MachineReadings

  it "runs memory low on the warning level with 171 MB free and a small swap", :aggregate_failures do
    expect(states(gauges(swap_mb: 1150.0, free: 0.17, pressure: 2.0))[:memory_state]).to eq("low")
    expect(states(gauges(swap_mb: 1150.0, free: 13.0, pressure: 4.0))[:memory_state]).to eq("low")
  end

  it "does not run memory low at the normal level, however little memory is free" do
    expect(states(gauges(swap_mb: 1150.0, free: 0.17, pressure: 1.0))[:memory_state]).to eq("ok")
  end

  it "keeps memory low until the level is back to normal", :aggregate_failures do
    expect(states(gauges(swap_mb: 100.0, free: 13.0, pressure: 2.0), memory: "low")[:memory_state]).to eq("low")
    expect(states(gauges(swap_mb: 100.0, free: 13.0, pressure: 1.0), memory: "low")[:memory_state]).to eq("ok")
  end

  it "judges by swap and free memory alone when the level cannot be read" do
    expect(states(gauges(swap_mb: 5000.0, free: 1.0, pressure: nil))[:memory_state]).to eq("low")
  end

  it "reads the level from what sysctl prints, and nothing from other text", :aggregate_failures do
    readings = Hecks::Adapters::MachineSampling::Readings.new(shell: nil)

    expect(readings.pressure("2\n")).to eq(2.0)
    expect(readings.pressure("")).to be_nil
  end
end
