require "spec_helper"
require_relative "support/machine_beats"

# A fill follows each reading and finds the state it left: a rise pauses every work item, a fall
# lets them start, and each reading that freed capacity rolls once.
RSpec.describe "the fill that follows a reading of the machine" do
  include MachineBeats

  def paused_after(*loads)
    registry = nil
    allow(Hecks::Adapters::MachineSampling).to receive(:new).and_wrap_original do |original, **args|
      registry = args[:registry]
      original.call(**args)
    end
    beat_through(loads.map { |load| gauge(60.0).merge(load: load) })
    Hecks::Adapters::Dispatching::Settings.new(registry).paused
  end

  it "rolls once for the reading that freed capacity, not for a rise or a quiet one", :aggregate_failures do
    beats = beat_through([9.0, 7.0, 7.0].map { |load| gauge(60.0).merge(load: load) })

    expect(beats[:rolls].size).to eq(1)
    expect(crossings(beats[:names])).to eq(%w[LoadRoseAbove LoadFellBelow])
  end

  it "pauses the fill after LoadRoseAbove, naming the load" do
    expect(paused_after(7.0, 9.0)).to include("paused by load")
  end

  it "lets the fill start work after LoadFellBelow" do
    expect(paused_after(9.0, 7.0)).to be_nil
  end
end
