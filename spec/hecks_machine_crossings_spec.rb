require "spec_helper"
require_relative "support/machine_beats"

# The machine's load is heard: a beat takes one reading behind the Sampling port, and the Delegate
# bluebook emits an event only when a state crosses its mark.
RSpec.describe "crossings of the machine's marks" do
  include MachineBeats

  def heard(*idles) = crossings(beat_through(idles.map { |idle| gauge(idle) })[:names])

  it "emits LoadFellBelow once for a falling series" do
    expect(heard(10.0, 20.0, 45.0, 50.0, 60.0)).to eq(%w[LoadRoseAbove LoadFellBelow])
  end

  it "emits LoadRoseAbove once for a rising series" do
    expect(heard(60.0, 50.0, 20.0, 10.0, 5.0)).to eq(%w[LoadRoseAbove])
  end

  it "emits nothing for a series that flaps inside the gap" do
    expect(heard(30.0, 38.0, 28.0, 35.0, 32.0)).to eq([])
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
