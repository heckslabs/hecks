# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/codebase/memory_wait"

# A heavy job does not start while memory is low by the Machine's own marks: it waits, says so,
# and starts once memory recovers, or after the give-up time, saying it runs anyway.
RSpec.describe Hecks::Adapters::Codebase::MemoryWait do
  let(:err) { StringIO.new }
  let(:marks) { Hecks::Adapters::MachineSampling::Marks::DEFAULTS }

  it "starts at once and names no wait while memory is not low" do
    expect(wait_with([reading(swap: 10.0)]).wait("gate")).to eq("")
  end

  it "waits while swap is over its mark and names the wait", :aggregate_failures do
    note = wait_with([reading(swap: 90.0), reading(swap: 60.0), reading(swap: 20.0)]).wait("gate")

    expect(note).to eq("waited 20 s while memory was low (the Machine's MemoryLow marks)")
    expect(err.string).to include("hecks: gate waiting: memory low")
  end

  it "keeps waiting inside the gap until memory has recovered" do
    readings = [reading(compressor: 20.0), reading(swap: 60.0), reading(swap: 10.0)]
    expect(wait_with(readings).wait("gate")).to start_with("waited 20 s")
  end

  it "runs anyway after the give-up time and says so" do
    note = wait_with([reading(swap: 95.0)] * 400).wait("spec_batch")
    expect(note).to eq("memory stayed low for 1800 s; spec_batch runs anyway")
  end

  it "polls at the Tickets world's memory_poll_seconds" do
    expect(described_class.poll_of(File.expand_path("..", __dir__))).to eq(10.0)
  end

  # A reading as the Sampling port answers it, with only the memory gauges set.
  def reading(swap: nil, compressor: nil)
    { cpu_idle: nil, load: nil, lane_waiting: nil, swap_used: swap, compressor_gb: compressor }
  end

  # A wait whose readings come from the list, one per look, on a clock that the pauses move.
  def wait_with(readings)
    now = [0.0]
    described_class.new(marks: marks, poll: 10.0, readings: -> { readings.shift || readings.last }, err: err,
                        clock: -> { now[0] }, pause: ->(seconds) { now[0] += seconds })
  end
end
