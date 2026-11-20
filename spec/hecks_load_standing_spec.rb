require "spec_helper"
require "hecks/hecks/adapters/dispatching"
require_relative "support/machine_beats"

# The load stands in one record of the machine, which every reading turns: a rise is recorded once
# and the first reading under the low mark records the fall, whatever each reading believes the one
# before it left, and the fill's pause reads that one standing.
RSpec.describe "the machine's one load standing" do
  include MachineBeats

  def beats_of(*loads) = beat_through(loads.map { |load| gauge(60.0).merge(load: load) })

  def history = Hecks::Adapters::MachineSampling::History

  def forgetful = allow(history).to receive(:new).and_return(instance_double(history, states: {}))

  it "clears the pause within one reading under the low mark", :aggregate_failures do
    beats = beats_of(11.0, 9.0)

    expect(crossings(beats[:names])).to eq(%w[LoadRoseAbove LoadFellBelow])
    expect(Hecks::Adapters::Dispatching::Settings.new(beats[:registry]).paused).to be_nil
  end

  it "stands above after a rise, whichever reading heard it" do
    expect(history.new(beats_of(9.0, 11.0)[:registry]).states[:load]).to eq("above")
  end

  it "records the fall when the reading under the mark remembers no rise before it" do
    forgetful

    expect(crossings(beats_of(11.0, 9.0)[:names])).to eq(%w[LoadRoseAbove LoadFellBelow])
  end

  it "records one rise for readings that each remember the load below" do
    forgetful

    expect(crossings(beats_of(11.0, 12.0, 13.0)[:names])).to eq(%w[LoadRoseAbove])
  end

  it "records the rise and the fall on the readings that heard them" do
    heard = beats_of(11.0, 12.0, 9.0)[:registry].event_log.select { |event| event.name.start_with?("Load") }

    expect(heard.map { |event| [event.name, event.id.to_s] }).to include(%w[LoadRoseAbove beat-0], %w[LoadFellBelow beat-2])
  end
end
