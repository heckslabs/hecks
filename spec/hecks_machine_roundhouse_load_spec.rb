# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/machine_sampling"

# With the `metering.roundhouse` switch on, Roundhouse's load is the machine's load: a reading
# under the low mark leaves the load below however busy the CPU looks, as one over the high mark
# leaves it above, so a rise is cleared by the next calm reading.
RSpec.describe "the machine's load read from Roundhouse" do
  before { Hecks::Adapters::MachineSampling.last = nil }

  def registry(roundhouse)
    world = Hecks::Bluebook::World.new(domain: "Tickets", settings: { "metering" => { roundhouse: roundhouse } })
    instance_double(Hecks::Runtime::Registry, world: world, bluebook: nil)
  end

  def state_of(load, roundhouse: true)
    gauges = { cpu_idle: 20.0, load: 0.0, swap_used_mb: 10.0, free_gb: 10.0, compressor_gb: 2.0, lane_waiting: nil }
    sampling = Hecks::Adapters::MachineSampling.new(
      registry: registry(roundhouse), settings: { readings: -> { gauges }, clock: -> { 0 }, meter: -> { load } }
    )
    sampling.read[:load_state]
  end

  it "leaves the load below for a metered load under the low mark, a busy CPU notwithstanding" do
    expect(state_of(6.0)).to eq("below")
  end

  it "leaves the load above for a metered load over the high mark" do
    expect(state_of(12.0)).to eq("above")
  end
end
