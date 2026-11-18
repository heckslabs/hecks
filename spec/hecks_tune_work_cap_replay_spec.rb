require "spec_helper"
require_relative "support/machine_beats"

# A replay of 2026-11-17: the states the machine's 620 kept readings left that day (one line each:
# the epoch second, memory ok or low, load below or above), beaten through the Hecks domain in
# Memory with the default bounds 2 and 10, and the moves the work cap would have made. That day the
# orchestrator moved the cap by hand on 30-minute passes; the replay climbs to 10 by 01:07, is cut
# to 2 by 02:15 when memory ran low, climbs again, and is cut twice in the evening's pressure.
RSpec.describe "the work cap over 2026-11-17's readings", :aggregate_failures do
  include MachineBeats

  FIXTURE = File.expand_path("fixtures/work_cap/readings_2026_11_17.txt", __dir__)

  CALM = { cpu_idle: 60.0, load: 3.0, swap_used: 1.0, swap_used_mb: 10.0, free_gb: 10.0, compressor_gb: 2.0,
           pressure_level: 1.0, lane_waiting: nil }.freeze

  # The gauges that leave each pair of states the fixture records.
  GAUGES = { %w[ok below] => CALM, %w[ok above] => CALM.merge(cpu_idle: 10.0, load: 25.0),
             %w[low below] => CALM.merge(pressure_level: 2.0, free_gb: 1.0),
             %w[low above] => CALM.merge(pressure_level: 2.0, free_gb: 1.0, cpu_idle: 10.0, load: 25.0) }.freeze

  # What the bluebook's rules give, worked by hand from the fixture: each move as the cap after it.
  MOVES = "+5 +6 +7 +8 +9 +10 -5 -2 +3 +4 +5 +6 +7 +8 +9 +10 -5 -2 +3 +4 +5 -2 +3 +4 -2 +3".freeze

  def series = File.readlines(FIXTURE).map { |line| GAUGES.fetch(line.split.drop(1)) }

  def replay
    MachineBeats::Sampling.last = nil
    registry = boot_hecks_in_memory(File.expand_path("../lib/hecks/hecks", __dir__)).registry
    readings = series
    Hecks::Runtime::AdapterLookup.standing_in(wiring(registry, readings.dup, [])) do
      readings.each_index.map { |index| cap_after_beat(registry, index) }
    end
  end

  def cap_after_beat(registry, index)
    beat(registry, index)
    registry.repository("Hecks", registry.bluebook("Hecks").aggregate("WorkCap")).find("pipeline")[:current][:value]
  end

  def signed(caps)
    caps.each_cons(2).filter_map { |was, now| "#{now > was ? "+" : "-"}#{now}" unless now == was }
  end

  it "makes the moves the rules give, and stays inside the bounds" do
    caps = replay

    expect(signed([4] + caps).join(" ")).to eq(MOVES)
    expect(caps.minmax).to eq([2, 10])
  end
end
