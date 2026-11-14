# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/codebase/memory_wait"

# A heavy job does not start while memory is low by the Machine's own marks: it waits, says so,
# and starts once memory recovers, or after the give-up time, saying it runs anyway.
RSpec.describe Hecks::Adapters::Codebase::MemoryWait do
  let(:err) { StringIO.new }
  let(:marks) { Hecks::Adapters::MachineSampling::Marks::DEFAULTS }

  it "starts at once and names no wait while memory is not low" do
    expect(wait_with([reading(swap: 500.0, free: 8.0)]).wait("gate")).to eq("")
  end

  it "does not wait on large idle swap while memory is free" do
    expect(wait_with([reading(swap: 9000.0, compressor: 20.0, free: 13.0)]).wait("gate")).to eq("")
  end

  it "waits under real pressure and names the wait and the reading", :aggregate_failures do
    note = wait_with([pressed, pressed, reading(swap: 500.0, free: 9.0)]).wait("gate")

    expect(note).to eq("waited 20 s while memory was low (swap 5000 MB over 4096, compressor 2.0 GB over 12.0, " \
                       "free 1.0 GB under 3.0)")
    expect(err.string).to include("hecks: gate waiting: memory low (swap 5000 MB over 4096")
  end

  it "keeps waiting inside the gap until memory has recovered" do
    readings = [pressed, reading(swap: 5000.0, free: 4.0), reading(swap: 5000.0, free: 8.0)]
    expect(wait_with(readings).wait("gate")).to start_with("waited 20 s")
  end

  it "runs anyway after the world's short give-up time and says what held it", :aggregate_failures do
    note = wait_with([pressed] * 400).wait("spec_batch")

    expect(note).to start_with("memory stayed low for 120 s (swap 5000 MB over 4096")
    expect(note).to end_with("spec_batch runs anyway")
  end

  it "reads the give-up time from the Tickets world" do
    expect(described_class.give_up_of(File.expand_path("..", __dir__))).to eq(120.0)
  end

  it "polls at the Tickets world's memory_poll_seconds" do
    expect(described_class.poll_of(File.expand_path("..", __dir__))).to eq(10.0)
  end

  # A reading as the Sampling port answers it, with only the memory gauges set.
  def reading(swap: nil, compressor: nil, free: nil)
    { cpu_idle: nil, load: nil, lane_waiting: nil, swap_used_mb: swap, compressor_gb: compressor, free_gb: free }
  end

  def pressed = reading(swap: 5000.0, compressor: 2.0, free: 1.0)

  # A wait whose readings come from the list, one per look, on a clock that the pauses move.
  def wait_with(readings)
    now = [0.0]
    described_class.new(marks: marks, poll: 10.0, readings: -> { readings.shift || readings.last }, err: err,
                        give_up: 120.0, clock: -> { now[0] }, pause: ->(seconds) { now[0] += seconds })
  end
end
