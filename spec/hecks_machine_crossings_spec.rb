require "spec_helper"
require_relative "support/machine_beats"

# The machine's load is heard: a beat takes one reading behind the Sampling port, and the Delegate
# bluebook emits an event only when a state crosses its mark.
RSpec.describe "crossings of the machine's marks" do
  include MachineBeats

  def heard(*loads) = crossings(beat_through(loads.map { |load| gauge(60.0).merge(load: load) })[:names])

  it "emits LoadFellBelow once for a falling series" do
    expect(heard(11.0, 11.5, 10.5, 9.0, 8.0)).to eq(%w[LoadRoseAbove LoadFellBelow])
  end

  it "emits LoadRoseAbove once for a rising series" do
    expect(heard(7.0, 9.0, 10.5, 11.0, 14.0)).to eq(%w[LoadRoseAbove])
  end

  it "emits nothing for a series that stays at or under the limit" do
    expect(heard(7.0, 9.5, 8.0, 10.0, 9.0)).to eq([])
  end

  it "hears memory run low and recover", :aggregate_failures do
    beats = [gauge(60.0, 86.0), gauge(60.0, 60.0), gauge(60.0, 40.0)]

    expect(crossings(beat_through(beats)[:names])).to eq(%w[MemoryLow MemoryRecovered])
  end

  it "hears the test lane turn busy and idle" do
    beats = [gauge(60.0, 10.0, 6.0), gauge(60.0, 10.0, 0.0)]

    expect(crossings(beat_through(beats)[:names])).to eq(%w[TestLaneBusy TestLaneIdle])
  end
end
