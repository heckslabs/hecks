require "spec_helper"
require "tmpdir"
require_relative "support/machine_history_rows"

# The reading the next one stands on is the one taken latest by its stamp. A store lists records
# by key, so a key that sorts after the beat's keys must not stand as the last reading for good:
# that kept every reading's load_before "below", and no fall of the load was heard.
RSpec.describe Hecks::Adapters::MachineSampling::History do
  include MachineHistoryRows

  def load_after(readings) = Dir.mktmpdir { |dir| sqlite_history_of(readings, dir).states[:load] }

  def stamped(at, load) = { load_state: load, taken_at: "2026-11-20T#{at}Z" }

  it "is not shadowed by an unstamped reading whose key sorts last" do
    readings = [["launchd-1", stamped("10:00:00", "below")], ["launchd-2", stamped("10:05:00", "above")],
                ["stall", { load_state: "below" }]]

    expect(load_after(readings)).to eq("above")
  end

  it "takes the latest stamp, not the latest key" do
    readings = [["launchd-2", stamped("10:05:00", "above")], ["zz-gate-1", stamped("09:00:00", "below")]]

    expect(load_after(readings)).to eq("above")
  end

  it "stands on the last listed reading while none is stamped, as the first stamped reading does" do
    expect(load_after([["launchd-1", { load_state: "above" }], ["stall", { load_state: "below" }]])).to eq("below")
  end
end
