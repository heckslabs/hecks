require "spec_helper"
require_relative "support/machine_beats"

# The load average crossing the fill's limit (the Tickets world's `dispatch_max_load`) is published
# as LoadRoseAbove / LoadFellBelow, and only a fall runs a fill.
RSpec.describe "the machine's load wakes the fill" do
  include MachineBeats

  def beats_of(*loads, idle: 60.0) = beat_through(loads.map { |load| gauge(idle).merge(load: load) })

  it "publishes one rise and one fall for 9, 9, 7", :aggregate_failures do
    beats = beats_of(11.0, 11.0, 9.0)

    expect(crossings(beats[:names])).to eq(%w[LoadRoseAbove LoadFellBelow])
    expect(beats[:rolls].size).to eq(1)
  end

  it "publishes nothing and fills nothing for 7, 7", :aggregate_failures do
    beats = beats_of(9.0, 9.0)

    expect(crossings(beats[:names])).to eq([])
    expect(beats[:rolls]).to be_empty
  end

  it "reads every beat as MachineRead" do
    expect(beats_of(11.0, 11.0, 9.0)[:names].count("MachineRead")).to eq(3)
  end

  it "lets the load decide when the CPU is nearly idle" do
    expect(crossings(beats_of(11.0, 11.0, idle: 99.0)[:names])).to eq(%w[LoadRoseAbove])
  end

  it "does not fill when memory runs low" do
    beats = beat_through([gauge(60.0, 86.0)])

    expect(beats[:rolls]).to be_empty
  end

  it "fills when memory recovers", :aggregate_failures do
    beats = beat_through([gauge(60.0, 86.0), gauge(60.0, 40.0)])

    expect(crossings(beats[:names])).to eq(%w[MemoryLow MemoryRecovered])
    expect(beats[:rolls].size).to eq(1)
  end

  it "starts one fill for a reading that crosses two marks" do
    beats = beat_through([gauge(60.0, 86.0).merge(load: 11.0), gauge(60.0, 40.0).merge(load: 9.0)])

    expect(beats[:rolls].size).to eq(1)
  end
end
