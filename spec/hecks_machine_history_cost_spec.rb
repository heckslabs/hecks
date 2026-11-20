require "spec_helper"
require "tmpdir"
require_relative "support/machine_history_rows"

# `History#states` reads every recorded reading on every reading, about one a minute. A scan of
# 10,000 readings (a week of them) measured about 0.13 ms in Memory and about 4,700 ms over SQLite,
# where each row is decoded; the spec holds the scan inside the 60,000 ms between readings.
RSpec.describe Hecks::Adapters::MachineSampling::History do
  include MachineHistoryRows

  it "finds the memory and lane states of the last saved reading among many" do
    states = history_over(10_000).states

    expect(states).to eq(memory: "low", lane: "idle")
  end

  it "scans 10,000 readings in Memory well inside the minute between readings", :wall_clock do
    held = history_over(10_000)

    expect_wall_clock(elapsed_ms { held.states }, under: 60_000)
  end

  it "scans 10,000 readings over SQLite inside the minute between readings", :wall_clock do
    Dir.mktmpdir do |dir|
      held = sqlite_history_over(10_000, dir)

      expect_wall_clock(elapsed_ms { held.states }, under: 60_000)
    end
  end
end
