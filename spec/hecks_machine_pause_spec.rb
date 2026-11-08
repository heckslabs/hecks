require "spec_helper"
require_relative "support/machine_beats"

# A fill follows each reading and finds the state it left: a rise pauses every work item, a fall
# lets them start, and each reading rolls once.
RSpec.describe "the fill that follows a reading of the machine" do
  include MachineBeats

  def paused_after(*idles)
    registry = nil
    allow(Hecks::Adapters::MachineSampling).to receive(:new).and_wrap_original do |original, **args|
      registry = args[:registry]
      original.call(**args)
    end
    beat_through(idles.map { |idle| gauge(idle) })
    Hecks::Adapters::Dispatching::Settings.new(registry).paused
  end

  it "rolls once for each reading", :aggregate_failures do
    beats = beat_through([gauge(10.0), gauge(60.0), gauge(60.0)])

    expect(beats[:rolls].size).to eq(3)
    expect(crossings(beats[:names])).to eq(%w[LoadRoseAbove LoadFellBelow])
  end

  it "pauses the fill after LoadRoseAbove, naming the load" do
    expect(paused_after(60.0, 10.0)).to include("paused by load")
  end

  it "lets the fill start work after LoadFellBelow" do
    expect(paused_after(10.0, 60.0)).to be_nil
  end
end
