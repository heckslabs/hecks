require "spec_helper"
require_relative "support/machine_beats"

# The work cap moves with the machine inside the owner's bounds: it rises by one after five calm
# readings, is halved on memory low twice in a row or the load over its mark for five readings,
# holds on one bad reading, never crosses the least, and does not rise while more than one train
# in three went red. The readings are a fake machine's, beaten through the Hecks domain in Memory.
RSpec.describe "the work cap the readings move", :aggregate_failures do
  include MachineBeats

  READING = { cpu_idle: 60.0, load: 3.0, swap_used: 1.0, swap_used_mb: 10.0, free_gb: 10.0, compressor_gb: 2.0,
              pressure_level: 1.0, lane_waiting: nil }.freeze

  READING_KINDS = { calm: {}, pressed: { pressure_level: 2.0, free_gb: 1.0 }, strained: { cpu_idle: 10.0, load: 25.0 } }.freeze

  def readings(*runs) = runs.each_slice(2).flat_map { |kind, count| [READING.merge(READING_KINDS.fetch(kind))] * count }

  def cap_after(series, before: nil)
    boot
    before&.call(@registry)
    Hecks::Runtime::AdapterLookup.standing_in(wiring(@registry, series.dup, [])) do
      series.each_index { |index| beat(@registry, index) }
    end
    @names = @registry.event_log.map(&:name)
    cap_record[:current][:value]
  end

  def boot
    MachineBeats::Sampling.last = nil
    @registry = boot_hecks_in_memory(File.expand_path("../lib/hecks/hecks", __dir__)).registry
  end

  def cap_record = @registry.repository("Hecks", @registry.bluebook("Hecks").aggregate("WorkCap")).find("pipeline")

  def red_trains(count)
    lambda do |registry|
      dispatcher = Hecks::Runtime::Dispatcher.new(registry)
      dispatcher.dispatch_flat("Hecks::WorkCap.Open", cap: { value: "pipeline" })
      count.times { dispatcher.dispatch_flat("Hecks::WorkCap.CountRedTrain", work_cap: "pipeline") }
    end
  end

  it "rises by one for each five calm readings, up to the most" do
    expect(cap_after(readings(:calm, 5))).to eq(5)
    expect(cap_after(readings(:calm, 15))).to eq(7)
    expect(cap_after(readings(:calm, 50))).to eq(10)
  end

  it "is halved on memory low twice in a row" do
    expect(cap_after(readings(:calm, 20, :pressed, 2))).to eq(4)
    expect(@names).to include("WorkCapWidened", "WorkCapNarrowed")
  end

  it "changes nothing on one bad reading" do
    expect(cap_after(readings(:pressed, 1, :calm, 1, :pressed, 1))).to eq(4)
    expect(cap_after(readings(:strained, 4, :calm, 1))).to eq(4)
    expect(@names).not_to include("WorkCapNarrowed")
  end

  it "is halved when the load stays over its mark for five readings" do
    expect(cap_after(readings(:strained, 5))).to eq(2)
  end

  it "never crosses the least" do
    expect(cap_after(readings(:pressed, 2, :pressed, 2, :strained, 5))).to eq(2)
  end

  it "does not rise while more than one train in three went red" do
    expect(cap_after(readings(:calm, 10), before: red_trains(1))).to eq(4)
    expect(@names).not_to include("WorkCapWidened")
  end
end
