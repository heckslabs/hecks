require "spec_helper"
require_relative "support/machine_beats"

# The Overload record says by itself, from the readings alone, that the machine has been overloaded
# long enough for the pipeline to add no work, and that it is clear again. It never touches the
# owner's roll switch.
RSpec.describe "the overload the readings declare", :aggregate_failures do
  include MachineBeats

  def reading(load, free: 10.0) = gauge(60.0, 10.0, nil, free: free).merge(load: load)

  def overload_after(series)
    @registry = nil
    beat_through_registry(series)
    record = @registry.repository("Hecks", @registry.bluebook("Hecks").aggregate("Overload")).find("pipeline")
    record[:standing][:value]
  end

  def beat_through_registry(series)
    MachineBeats::Sampling.last = nil
    @registry = boot_hecks_in_memory(File.expand_path("../lib/hecks/hecks", __dir__)).registry
    rolls = []
    Hecks::Runtime::AdapterLookup.standing_in(wiring(@registry, series.dup, rolls)) do
      series.each_index { |index| beat(@registry, index) }
    end
    @names = @registry.event_log.map(&:name)
  end

  it "declares the overload when the load stays over 20 for five readings" do
    expect(overload_after(Array.new(5) { reading(25.0) })).to eq(1)
    expect(@names.count("OverloadDeclared")).to eq(1)
  end

  it "does not declare it for one reading at 30, nor for a run broken by one at 15" do
    expect(overload_after([reading(30.0)])).to eq(0)
    expect(overload_after([25.0, 25.0, 25.0, 15.0, 25.0, 25.0].map { |load| reading(load) })).to eq(0)
  end

  it "declares it when memory stays low for three readings" do
    expect(overload_after(Array.new(3) { reading(5.0, free: 1.0).merge(swap_used_mb: 5000.0) })).to eq(1)
  end

  it "lifts it after ten readings under the load limit" do
    series = Array.new(5) { reading(25.0) } + Array.new(10) { reading(5.0) }

    expect(overload_after(series)).to eq(0)
    expect(@names).to include("OverloadDeclared", "OverloadLifted")
  end

  it "keeps it while fewer than ten readings are under the limit, and leaves the roll switch alone" do
    series = Array.new(5) { reading(25.0) } + Array.new(9) { reading(5.0) }

    expect(overload_after(series)).to eq(1)
    expect(@names).not_to include("RollPaused", "RollResumed")
  end
end
